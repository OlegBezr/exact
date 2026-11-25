package dev.exact.canvas

import android.content.ClipData
import android.content.ClipDescription
import android.net.Uri
import android.provider.DocumentsContract
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
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
@Config(sdk = [33], manifest = Config.NONE, shadows = [DragInTest.Journal::class])
class DragInTest {
    @Before fun begin() { Journal.lines.clear() }

    /** exact2's journal, as the reader writes to it with no owner. */
    @Implements(Native::class, isInAndroidSdk = false)
    class Journal {
        companion object {
            val lines = ArrayList<String>()
            @JvmStatic @Implementation fun __staticInitializer__() {}
            @JvmStatic @Implementation fun journal(line: String) { lines += line }
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

    @Test fun aContentOrFileUriIsAFileAndAnyOtherIsTheLink() {
        val photo = Uri.parse("content://photos/1")
        val note = Uri.parse("file:///sdcard/note.txt")
        val items = DropItems.read(clip(ClipData.Item(photo), ClipData.Item(Uri.parse("mailto:a@example.com")), ClipData.Item(note),
            ClipData.Item(Uri.parse("https://example.com/second"))))
        assertEquals(DropItems(listOf(photo, note), "", "mailto:a@example.com"), items)
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

    @Test fun aFieldGivesAwayADragItsNodeOrADropAboveItTakes() {
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
        val paths = DropItems.copy(resolver, into, listOf(first, folder, second, unread))
        assertEquals(listOf("photo.png", "photo.png"), paths.map { File(it).name })
        assertEquals(listOf("first", "second"), paths.map { File(it).readText() })
        assertTrue(paths.all { File(it).canonicalPath.startsWith(into.canonicalPath) })
        assertEquals(listOf("drop: a folder was left out: a drop takes files"), Journal.lines.take(1))
        assertTrue(Journal.lines[1], Journal.lines.size == 2 && Journal.lines[1].startsWith("drop: an item could not be read"))
        assertNotEquals("each drop has a folder of its own", into, DropStaging.next(context))
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
