package dev.exact.canvas

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.net.Uri
import android.provider.DocumentsContract
import android.view.DragEvent
import android.view.View
import android.widget.EditText
import android.widget.FrameLayout
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import java.io.File

/** Drags from other apps (LLP 1094.001 D5): what a drop's items are, which drags the window takes, which a field gives
 * away, and the copies a drop's files become. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 33], manifest = Config.NONE, shadows = [DragInTest.Journal::class])
class DragInTest {
    @Before fun begin() { Journal.lines.clear(); Journal.drags.clear() }

    /** exact2's journal, as the reader writes to it with no owner. */
    @Implements(Native::class, isInAndroidSdk = false)
    class Journal {
        companion object {
            val lines = ArrayList<String>()
            /** What the reader told exact2 of drags, in order. */
            val drags = ArrayList<String>()
            @JvmStatic @Implementation fun __staticInitializer__() {}
            @JvmStatic @Implementation fun journal(line: String) { lines += line }
            @JvmStatic @Implementation fun dragOver(x: Float, y: Float) { drags += "over ${x.toInt()} ${y.toInt()}" }
            @JvmStatic @Implementation fun dragLeft() { drags += "left" }
            @JvmStatic @Implementation fun dragDropped() { drags += "ended" }
            @JvmStatic @Implementation fun dropReleased(x: Float, y: Float): Int { drags += "released ${x.toInt()} ${y.toInt()}"; return 0 }
            @JvmStatic @Implementation fun dropLanded(id: Int, items: String) { drags += "landed $id $items" }
            /** Whether a field is painted where a drop lands; the tests' fields always are. */
            @JvmStatic @Implementation fun fieldUnder(id: Int, x: Float, y: Float): Boolean = true
        }
    }

    private fun clip(vararg items: ClipData.Item): ClipData =
        ClipData(ClipDescription("drag", arrayOf(ClipDescription.MIMETYPE_TEXT_PLAIN)), items.first()).apply { items.drop(1).forEach(::addItem) }

    @Test fun textItemsJoinAndTheFirstWebLinkAmongThemIsTheLink() {
        val items = DropItems.read(clip(ClipData.Item("Mount Fuji"), ClipData.Item("https://example.com/fuji"),
            ClipData.Item("https://example.com/later"), ClipData.Item("Japan")))
        assertEquals(DropItems(emptyList(), "Mount Fuji\nhttps://example.com/later\nJapan", "https://example.com/fuji"), items)
        assertEquals("a link inside text stays text", "",
            DropItems.read(clip(ClipData.Item("see https://example.com/fuji"))).url)
        assertEquals("Chrome's link: its title, a line break, its address", DropItems(emptyList(), "A link to Fuji", "https://example.com/fuji"),
            DropItems.read(clip(ClipData.Item("A link to Fuji\nhttps://example.com/fuji"))))
    }

    @Test fun aContentUriIsAFileAFileUriIsNoneAndAnyOtherIsTheLink() {
        val photo = Uri.parse("content://photos/1")
        val note = Uri.parse("file:///sdcard/note.txt")
        val items = DropItems.read(clip(ClipData.Item(photo), ClipData.Item(Uri.parse("mailto:a@example.com")), ClipData.Item(note),
            ClipData.Item(Uri.parse("https://example.com/second"))))
        assertEquals("a file: URI is read with the app's own rights, so it is no file to take",
            DropItems(listOf(photo), "", "mailto:a@example.com"), items)
        assertEquals("a raw web link", "https://example.com/",
            DropItems.read(ClipData.newRawUri("link", Uri.parse("https://example.com/"))).url)
        assertEquals("the reader's JSON", """{"paths":["\/a"],"text":"","url":"mailto:a@example.com"}""", items.json(listOf("/a")))
    }

    @Test fun aDragOfOnlyAnAppOrAnIntentFindsNoTarget() {
        fun carries(vararg types: String) = DragIn.carries(ClipDescription("drag", types))
        assertFalse(carries("application/vnd.android.activity"))
        assertFalse(carries(ClipDescription.MIMETYPE_TEXT_INTENT, "application/vnd.android.task"))
        assertTrue(carries(ClipDescription.MIMETYPE_TEXT_PLAIN))
        assertTrue(carries(ClipDescription.MIMETYPE_TEXT_URILIST))
        assertTrue(carries("application/vnd.android.shortcut", "image/png"))
        assertFalse("an app's own type", carries("chrome/tab"))
        assertFalse(DragIn.carries(null))
    }

    @Test fun aFieldGivesAwayADragItsNodeOrADropAboveItTakesAtItsStart() {
        val image = ClipDescription("drag", arrayOf("image/png"))
        val text = ClipDescription("drag", arrayOf(ClipDescription.MIMETYPE_TEXT_PLAIN, ClipDescription.MIMETYPE_TEXT_URILIST))
        assertTrue("its own node takes every drag", DragIn.givenAway(1, text))
        assertTrue("a file goes to the drop above", DragIn.givenAway(2, image))
        assertFalse("text and a URI list stay the field's", DragIn.givenAway(2, text))
        assertFalse("Chrome's link: its text, an intent and its own type", DragIn.givenAway(2,
            ClipDescription("link", arrayOf(ClipDescription.MIMETYPE_TEXT_PLAIN, ClipDescription.MIMETYPE_TEXT_INTENT, "chrome/link"))))
        assertFalse("with no drop, the field keeps whatever its text view takes", DragIn.givenAway(0, image))
    }

    @Test fun eachFileIsCopiedUnderItsOwnNameAndAFolderOrAnUnreadableItemIsLeftOut() {
        val context = RuntimeEnvironment.getApplication()
        val resolver = context.contentResolver
        org.robolectric.shadows.ShadowContentResolver.registerProviderInternal("names", FilePickerTest.PhotoProvider())
        org.robolectric.shadows.ShadowContentResolver.registerProviderInternal("folders", Folders())
        val (first, second, folder, unread) = listOf("content://names/a", "content://names/b", "content://folders/f", "content://names/c").map(Uri::parse)
        shadowOf(resolver).registerInputStream(first, "first".byteInputStream())
        shadowOf(resolver).registerInputStream(second, "second".byteInputStream())
        val into = DropStaging.next(context)
        val paths = DropItems.copy(resolver, into, listOf(first, folder, second, unread), Journal.lines::add)
        assertEquals(listOf("photo.png", "photo.png"), paths.map { File(it).name })
        assertEquals(listOf("first", "second"), paths.map { File(it).readText() })
        assertTrue(paths.all { File(it).canonicalPath.startsWith(into.canonicalPath) })
        assertEquals(listOf("drop: a folder was left out: a drop takes files"), Journal.lines.take(1))
        assertTrue(Journal.lines[1], Journal.lines.size == 2 && Journal.lines[1].startsWith("drop: an item could not be read"))
        assertEquals("the unread item leaves no folder", listOf("0", "2"), into.list()!!.sorted())
        assertNotEquals("each drop has a folder of its own", into, DropStaging.next(context))
    }

    @Test fun aTextFileStaysTheFieldsAndAnyOtherContentItemIsAFile() {
        val resolver = RuntimeEnvironment.getApplication().contentResolver
        org.robolectric.shadows.ShadowContentResolver.registerProviderInternal("typed", Typed())
        fun holds(vararg uris: String) = DragIn.holdsFile(ClipData("drag", arrayOf(ClipDescription.MIMETYPE_TEXT_URILIST), ClipData.Item(Uri.parse(uris[0])))
            .apply { uris.drop(1).forEach { addItem(ClipData.Item(Uri.parse(it))) } }, resolver)
        assertFalse(holds("content://typed/notes.txt"))
        assertTrue(holds("content://typed/notes.txt", "content://typed/photo.png"))
        assertTrue("a type the provider does not say", holds("content://typed/unknown"))
        assertFalse("a web link", holds("https://example.com/"))
    }

    class Typed : android.content.ContentProvider() {
        override fun onCreate() = true
        override fun getType(uri: Uri) = when (uri.lastPathSegment) { "notes.txt" -> "text/plain"; "photo.png" -> "image/png"; else -> null }
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?) = null
        override fun insert(uri: Uri, values: android.content.ContentValues?) = null
        override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0
        override fun update(uri: Uri, values: android.content.ContentValues?, selection: String?, args: Array<out String>?) = 0
    }

    /** A drag event as Android's window sends one: the platform's own `DragEvent.obtain`, whose parameters differ by
     * API level, given each by its type (the action, the point and then zero offsets, the description and the clip). */
    private fun event(action: Int, x: Float = 0f, y: Float = 0f, clip: ClipData? = null, description: ClipDescription? = clip?.description): DragEvent {
        val obtain = DragEvent::class.java.declaredMethods
            .filter { it.name == "obtain" && it.parameterTypes.firstOrNull() == Int::class.javaPrimitiveType }
            .maxBy { it.parameterCount }
        val floats = ArrayDeque(listOf(x, y))
        val args = obtain.parameterTypes.map { type ->
            when (type) {
                Int::class.javaPrimitiveType -> action
                Float::class.javaPrimitiveType -> floats.removeFirstOrNull() ?: 0f
                Boolean::class.javaPrimitiveType -> false
                ClipDescription::class.java -> description
                ClipData::class.java -> clip
                else -> null
            }
        }
        return obtain.invoke(null, *args.toTypedArray()) as DragEvent
    }

    /** Two fields, ids 1 and 2, 300 by 60 at (20, 40) and (20, 200), on a root as the reader lays them out; with
     * [flags] for the second. Its text view. */
    private fun twoFields(flags: Int, clipSecond: Boolean = false): Pair<Root, EditText> {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = Root(activity)
        val fields = Fields(activity)
        root.addView(fields, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        activity.setContentView(root)
        fields.told(FieldsTest.Companion.statement(listOf(
            FieldsTest.Companion.Told(1, 20f, 40f, 300f, 60f, 1),
            FieldsTest.Companion.Told(2, 20f, 200f, 300f, 60f, flags, clip = if (clipSecond) floatArrayOf(0f, 0f, 400f, 100f) else null),
        )))
        root.measure(View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, 400, 400)
        val second = (0 until fields.childCount).map { (fields.getChildAt(it) as FrameLayout).getChildAt(0) as FieldText }.first { it.text.toString() == "2" }
        return root to second
    }

    private fun dragText(root: Root, x: Float, y: Float) {
        val clip = ClipData.newPlainText("drag", "Fuji")
        root.dispatchDragEvent(event(DragEvent.ACTION_DRAG_STARTED, description = clip.description))
        root.dispatchDragEvent(event(DragEvent.ACTION_DRAG_LOCATION, x, y, description = clip.description))
        root.dispatchDragEvent(event(DragEvent.ACTION_DROP, x, y, clip))
        root.dispatchDragEvent(event(DragEvent.ACTION_DRAG_ENDED, description = clip.description))
    }

    @Test fun aTextDropReachesTheLowerOfTwoFieldsWhichInsertsIt() {
        val (root, second) = twoFields(flags = 1 or 8)
        dragText(root, 170f, 230f)
        assertTrue(second.text.toString(), second.text.toString().contains("Fuji"))
        assertEquals("the field told where the drag was, then that it took the drop", listOf("over 170 230", "ended"), Journal.drags)
    }

    @Test fun aFieldWhoseNodeTakesDropsGivesTheDragToTheRoot() {
        val (root, second) = twoFields(flags = 1 or 4)
        dragText(root, 170f, 230f)
        assertEquals("2", second.text.toString())
        assertEquals(listOf("over 170 230", "released 170 230"), Journal.drags)
    }

    @Test fun aFieldClippedAwayWholeHasAPortNoDragFinds() {
        val (root, second) = twoFields(flags = 1 or 8, clipSecond = true)
        assertEquals(listOf(0, 0), (second.parent as View).let { listOf(it.width, it.height) })
        dragText(root, 170f, 230f)
        assertEquals("2", second.text.toString())
    }

    class Folders : android.content.ContentProvider() {
        override fun onCreate() = true
        override fun getType(uri: Uri) = DocumentsContract.Document.MIME_TYPE_DIR
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?) = null
        override fun insert(uri: Uri, values: android.content.ContentValues?) = null
        override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0
        override fun update(uri: Uri, values: android.content.ContentValues?, selection: String?, args: Array<out String>?) = 0
    }
}
