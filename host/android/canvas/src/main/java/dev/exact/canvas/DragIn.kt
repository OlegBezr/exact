package dev.exact.canvas

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.view.DragEvent
import android.view.View
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException

/**
 * Drags into the window, from another app or from this one (LLP 1094.001 D5). The root hears every drag in its own
 * `onDragEvent`, since Android tells a view of a drag's end only where the view took its start; a listener would also
 * offer the root to accessibility services as a drop target, whose Drop lands at its middle, where no node may take it
 * (`View.canAcceptAccessibilityDrop`). It tells exact2's tracker (`presenter/file_drop.rs`) where the drag is: exact2
 * sends the nodes under it their `dragenter` and `dragleave` and finds the innermost node that takes a `drop`. A hosted
 * field tells it too, and gives the root a drag that D2 gives a node ([field]); a drag of text that it keeps it
 * inserts as an `EditText` does. The root and the page's view lie at the same place, so the root's pixels are the
 * view's, which exact2 reads a touch in.
 */
internal class DragIn(private val root: View) {
    /** Whether the window has heard a drag start and not yet its end ([Root.dragging]). */
    var dragging = false
        private set

    /** Whether the drag carries a file, text or a link, as its description says ([carries]). */
    private var carries = false

    /** Whether the drag owes exact2 no leave at its end: it was released, or a field took it. */
    private var settled = false

    private val main = Handler(Looper.getMainLooper())

    /** An exit's leave, on the next turn unless the drag is told again first, as when it moves between the root and a
     * field that keeps it, and each tells it from there (D2). */
    private val exit = Runnable { if (dragging && !settled) Exact.dragLeft() }

    /** The root's drag event: whether it takes it. */
    fun heard(event: DragEvent): Boolean {
        when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> { dragging = true; settled = false; carries = carries(event.clipDescription) }
            DragEvent.ACTION_DRAG_LOCATION -> over(event.x, event.y)
            DragEvent.ACTION_DRAG_EXITED -> exited()
            DragEvent.ACTION_DROP -> return drop(event, event.x, event.y)
            DragEvent.ACTION_DRAG_ENDED -> {
                dragging = false
                main.removeCallbacks(exit)
                if (carries && !settled) Exact.dragLeft()
            }
        }
        return true
    }

    /**
     * What hosted field [field] answers [event] with; null for the field to take it as its `EditText` does. A field
     * that takes no touch (disabled, or covered) takes no drag. It gives the root a drag at its start when its own node
     * takes drops, or when a node above it does and the drag carries a file's type. A URI list may be a link or a
     * file, so the field keeps it, and gives the root at the drop a `content:` item that is no text, as a file, under
     * a node that takes it. Exact2 tells each field who takes a drop over it with every frame, so this reads no answer
     * from exact2's thread.
     */
    fun field(field: FieldText, event: DragEvent): Boolean? {
        val at = IntArray(2).also(field::getLocationInWindow)
        val base = IntArray(2).also(root::getLocationInWindow)
        val (x, y) = event.x + at[0] - base[0] to event.y + at[1] - base[1]
        val gives = field.inert || field.dropOwner == 1
        return when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> if (field.inert || givenAway(field.dropOwner, event.clipDescription)) false else null
            DragEvent.ACTION_DRAG_LOCATION -> { over(x, y); null }
            DragEvent.ACTION_DRAG_EXITED -> { exited(); null }
            DragEvent.ACTION_DROP ->
                if (gives || field.dropOwner == 2 && event.clipData?.let { holdsFile(it, field.context.contentResolver) } == true) drop(event, x, y)
                else null
            else -> null
        }
    }

    /** A field the drag was over took its drop, or refused it: the nodes under the drag hear their leave, after the
     * enters it waited for (D2). */
    fun fieldDropped() {
        main.removeCallbacks(exit)
        settled = true
        Exact.dragDropped()
    }

    /** The drag is at ([x], [y]) in the root's pixels. */
    private fun over(x: Float, y: Float) {
        main.removeCallbacks(exit)
        if (carries) Exact.dragOver(x, y)
    }

    private fun exited() {
        main.removeCallbacks(exit)
        main.post(exit)
    }

    /**
     * The drag was released at ([x], [y]): exact2 takes its target and the nodes under it at once, and its items when
     * they arrive. Text and a link arrive with it; each `content:` item is copied into a folder of the drop's own off
     * the main thread, under the read permission Android grants for the drop, which is released once the copies end.
     * Whether the window took the drop.
     */
    private fun drop(event: DragEvent, x: Float, y: Float): Boolean {
        main.removeCallbacks(exit)
        val clip = event.clipData
        if (!carries || clip == null) return false
        settled = true
        val id = Exact.dropReleased(x, y)
        if (id == 0) return false
        val items = DropItems.read(clip)
        if (items.files.isEmpty()) {
            Exact.dropLanded(id, items.json(emptyList()))
            return true
        }
        val context = root.context.applicationContext
        val said = ArrayList<String>()
        var grant: android.view.DragAndDropPermissions? = null
        // Every way it ends lands the drop once, on the main thread, and releases the grant: its copies, or none
        val land = { paths: List<String> ->
            main.post {
                grant?.release()
                said.forEach(Exact::journal)
                Exact.dropLanded(id, items.json(paths))
            }
        }
        try {
            grant = (root.context as? Activity)?.requestDragAndDropPermissions(event)
            Thread({
                val paths = try { DropItems.copy(context.contentResolver, DropStaging.next(context), items.files, said::add) } catch (e: Exception) {
                    said += "drop: its files could not be copied: ${e.message ?: e.javaClass.simpleName}, so it delivers its text and link alone"
                    emptyList()
                }
                land(paths)
            }, "exact-drop").start()
        } catch (e: RuntimeException) {
            said += "drop: its files could not be read: ${e.message ?: e.javaClass.simpleName}, so it delivers its text and link alone"
            land(emptyList())
        }
        return true
    }

    companion object {
        /** Android's own types for an app, a shortcut, a task and an intent, as a launcher's drag carries: none is a
         * file, text or a link. */
        private val ANDROID_OWN = setOf(
            ClipDescription.MIMETYPE_TEXT_INTENT, "application/vnd.android.activity", "application/vnd.android.shortcut",
            "application/vnd.android.task",
        )

        /** The top-level media types of files ([RFC 6838 §4.2](https://www.rfc-editor.org/rfc/rfc6838#section-4.2)), text
         * aside: an app's own type, as Chrome's `chrome/link` beside a link's text, is none. */
        private val FILES = setOf("application", "audio", "font", "image", "model", "video")

        private fun text(type: String) = type.startsWith("text/") && type !in ANDROID_OWN
        private fun file(type: String) = type.substringBefore('/') in FILES && type !in ANDROID_OWN

        private fun types(description: ClipDescription?): List<String> =
            if (description == null) emptyList() else List(description.mimeTypeCount, description::getMimeType)

        /** Whether a drag with [description] carries a file, text or a link: one that carries none finds no target. */
        fun carries(description: ClipDescription?): Boolean = types(description).any { text(it) || file(it) }

        /** Whether a field gives a drag with [description] to the root at its start, its node's [owner] being 0 (no
         * node takes a drop over it), 1 (its own does) or 2 (one above it does). */
        fun givenAway(owner: Int, description: ClipDescription?): Boolean =
            owner == 1 || owner == 2 && types(description).any(::file)

        /** Whether [clip] holds a `content:` item that is no text by its provider's type: a file, which a field gives
         * to the node above it, where a text file is the field's (D2). */
        fun holdsFile(clip: ClipData, resolver: ContentResolver): Boolean = (0 until clip.itemCount).any { i ->
            val uri = clip.getItemAt(i).uri
            uri?.scheme == ContentResolver.SCHEME_CONTENT &&
                (try { resolver.getType(uri) } catch (e: Exception) { null })?.let(::text) != true
        }
    }
}

/**
 * What a drop carries (LLP 1094.001 D1, D5): its files, as `content:` URIs, its text items joined by line breaks, and
 * its first link that is not a file. A `file:` URI is no file to take: Android shares files between apps as content
 * URIs, which the drop's grant covers, and a path would be read with the app's own rights. Android's sources send a
 * link as a text item: Exact's own, a link alone in an item (LLP 1094.000 D7); Chrome's, its title, a line break and
 * its address. So while there is no link yet, a text item whose last line is one `http:` or `https:` link is that
 * link, and its lines before it are text, as a link card's title is on iOS; a link anywhere else stays text.
 */
internal data class DropItems(val files: List<Uri>, val text: String, val url: String) {
    /** The items as exact2 reads them (`CanvasHost::drop_landed`), with the copies' [paths]. */
    fun json(paths: List<String>): String =
        JSONObject().put("paths", JSONArray(paths)).put("text", text).put("url", url).toString()

    companion object {
        private val LINK = Regex("https?://\\S+", RegexOption.IGNORE_CASE)

        fun read(clip: ClipData): DropItems {
            val files = ArrayList<Uri>()
            val texts = ArrayList<String>()
            var url = ""
            for (i in 0 until clip.itemCount) {
                val item = clip.getItemAt(i)
                item.uri?.let { uri ->
                    when (uri.scheme?.lowercase(java.util.Locale.ROOT)) {
                        ContentResolver.SCHEME_CONTENT -> files.add(uri)
                        ContentResolver.SCHEME_FILE -> {}
                        else -> if (url.isEmpty()) url = uri.toString()
                    }
                }
                val text = item.text?.toString() ?: continue
                val last = text.substringAfterLast('\n')
                if (url.isEmpty() && LINK.matches(last)) {
                    url = last
                    text.substringBeforeLast('\n', "").takeIf { it.isNotEmpty() }?.let(texts::add)
                } else texts.add(text)
            }
            return DropItems(files, texts.joinToString("\n"), url)
        }

        /** Copies each of [uris] into a folder of its own under [into], named as its provider names it, so equal
         * names keep apart: their paths, in order. A folder is not taken, and an item that cannot be read leaves no
         * part of a copy; each is told to [said] and left out. */
        fun copy(resolver: ContentResolver, into: File, uris: List<Uri>, said: (String) -> Unit): List<String> = uris.mapIndexedNotNull { i, uri ->
            val dir = File(into, "$i")
            try {
                if (resolver.getType(uri) == DocumentsContract.Document.MIME_TYPE_DIR) {
                    said("drop: a folder was left out: a drop takes files")
                    return@mapIndexedNotNull null
                }
                if (!dir.mkdirs()) throw IOException("could not make the drop's folder")
                val file = File(dir, FilePicker.displayName(resolver, uri, i))
                (resolver.openInputStream(uri) ?: throw IOException("no stream for the item")).use { from ->
                    Files.output(file).use { to -> from.copyTo(to) }
                }
                file.absolutePath
            } catch (e: Exception) {
                dir.deleteRecursively()
                said("drop: an item could not be read: ${e.message ?: e.javaClass.simpleName}, so the drop leaves it out")
                null
            }
        }
    }
}

/** Where drops' copies stay: the process's, emptied once as it first takes a drop, since a new process holds no
 * handle to an earlier one's copies. Each drop has a folder of its own. */
internal object DropStaging {
    private var root: File? = null

    @Synchronized fun next(context: Context): File {
        val root = root ?: File(context.cacheDir, "exact-drops").also {
            it.deleteRecursively()
            root = it
        }
        java.nio.file.Files.createDirectories(root.toPath())
        return java.nio.file.Files.createTempDirectory(root.toPath(), "drop-").toFile()
    }
}
