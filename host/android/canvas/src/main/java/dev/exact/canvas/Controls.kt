package dev.exact.canvas

import android.app.KeyguardManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import org.json.JSONArray

/**
 * A control in Quick Settings (LLP 1126.004 D5): the tile of one `controls` row of app.json, which the build generates
 * as a subclass naming the row's kind, the bake's dispatch digest and how the bake placed it (`app/build.gradle.kts`).
 * The system draws it in its inactive appearance, with the row's description under its title, and binds it with
 * `BIND_QUICK_SETTINGS_TILE`; its [onClick] is the person's press.
 *
 * - `open`, a URL control: the app opens at the location, as a notification's tap opens one ([Activations.intent]).
 * - `tool`: the press runs the tool where it is ([Controls.press]), in a host [Headless] boots when no activity shows
 *   the app, as origin `action` even with one. On a Lock Screen that holds a credential, `required` and `local` ask
 *   the person for it and press once they have ([ControlPress]); `always` presses there.
 * - `foreground`, a tool whose reach starts a capture: a tile click grants no while-in-use microphone, so the press
 *   opens the app and is pressed from it in front ([Controls.handoff]), still as origin `action`: the app in front is
 *   what Android needs to hand the press the microphone, not a grant of the app's authority. `always` refuses on a
 *   Lock Screen that holds a credential, since the app cannot come to the front there.
 *
 * [Tile service](https://developer.android.com/reference/android/service/quicksettings/TileService)
 */
abstract class ControlTile(
    private val kind: String,
    private val digest: String,
    private val intent: String,
    private val url: String?,
    private val authentication: String,
    private val description: String?,
) : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.subtitle = description
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        // A press is the person's last only until they press another tile.
        Controls.superseded()
        // `required` and `local` ask for the device's credential where the Lock Screen holds one ([isSecure]); a
        // keyguard with none to ask (a swipe, or Smart Lock's trust) is no lock to them.
        when (intent) {
            // Each launch its own `PendingIntent`: a one-shot one another tile or a notification made never matches.
            // Starting the app asks the person to unlock first, as any activity a tile starts on the Lock Screen does.
            "open" -> launch(Activations.intent(this, "", "", JSONArray(), url).setIdentifier(java.util.UUID.randomUUID().toString()))
            "foreground" ->
                if (isSecure && authentication == "always") Controls.refuse(kind, "the app records only in front, and the phone is locked")
                else launch(Controls.handoff(this, kind, digest))
            else -> when {
                authentication == "always" || !isSecure -> Controls.press(this, kind, digest, SystemClock.elapsedRealtime())
                // `unlockAndRun`'s continuation waits for SystemUI to bind the tile again, by when the process may be
                // frozen; an activity the tile starts runs once the person unlocks, and presses where it is.
                else -> launch(ControlPress.intent(this, kind, digest))
            }
        }
    }

    /** Start the app's activity and close the shade: from API 34 by an immutable one-shot `PendingIntent`, which the
     * `Intent` overload is refused for. */
    private fun launch(intent: Intent) {
        if (Build.VERSION.SDK_INT >= 34) {
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, flags))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}

/**
 * A control's press reaching the app (LLP 1126.004 D2, D5), on the main thread.
 *
 * A tile that opens the app ([handoff]) leaves a one-use record in this process and names it in the intent it starts,
 * which goes to `.Control`, an `<activity-alias>` with `android:exported="false"`. [receive] takes the record off the
 * intent and consumes it before anything else: a replayed intent, a recreated activity's or one in a process that
 * replaced the tile's finds none and is dropped. The press waits ([ready]) until the activity is resumed, has drawn a
 * frame of the running generation since it last started, the phone is unlocked and the data module is active, then
 * runs. A later press, the activity's stop, a data module that failed, or [BOUND_MS] from the click drops it. Once
 * running, a press is one call in the runner, and a later press, its activity's stop or the screen turning off end
 * that call ([end]); its bound ends it there too.
 */
internal object Controls {
    const val ALIAS = "dev.exact.app.Control"
    private const val TOKEN = "dev.exact.control.token"
    /** How long a press may take to reach an app ready to run it: the host's boot bound. */
    private const val BOUND_MS = 20_000L

    /** A press's record: its control, when the tile was pressed ([SystemClock.elapsedRealtime], which counts the
     * phone's sleep), and whether its process had no host then. */
    private class Record(val token: String, val kind: String, val digest: String, val at: Long, val cold: Boolean) {
        fun late() = SystemClock.elapsedRealtime() - at > BOUND_MS
    }
    private fun record(kind: String, digest: String) =
        Record(java.util.UUID.randomUUID().toString(), kind, digest, SystemClock.elapsedRealtime(), !Exact.live)
    /** The last tile press's record, until its intent arrives: a press supersedes the one before it. */
    private var issued: Record? = null
    /** The record an arrived intent named, until the activity it reached is ready to run it. */
    private var pending: Record? = null
    private var receiver: java.lang.ref.WeakReference<ExactActivity>? = null
    /** The record whose data module [ready] is waiting for. */
    private var asking: Record? = null
    /** The locked tool presses [ControlPress] has yet to run, by token. */
    private val unlocking = HashMap<String, Record>()
    private val main = Handler(Looper.getMainLooper())

    /** The intent a tile starts to press [kind] from the app in front, superseding any press waiting: its record's
     * token, also the intent's identifier, so no `PendingIntent` another press made matches it. Starting it asks the
     * person to unlock first. */
    fun handoff(context: Context, kind: String, digest: String): Intent {
        val record = record(kind, digest).also { issued = it }
        return Intent().setComponent(ComponentName(context.packageName, ALIAS)).setIdentifier(record.token)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(TOKEN, record.token)
    }

    /** The one-use token [ControlPress] runs a locked tool press by. */
    fun unlockPress(kind: String, digest: String): String {
        val now = SystemClock.elapsedRealtime()
        unlocking.values.removeAll { now - it.at > BOUND_MS }
        return record(kind, digest).also { unlocking[it.token] = it }.token
    }

    /** The locked press [token] names, run once the person has unlocked: taken from the records only then, so a later
     * click, which clears them, or the bound supersedes it while it waits. */
    fun unlocked(token: String): (Context) -> Unit = { context ->
        val record = unlocking.remove(token)?.takeUnless { it.late() }
        if (record == null) journal("control: a locked press already taken, superseded or late was dropped")
        else press(context, record.kind, record.digest, record.at, record.cold)
    }

    /** The runner's call of the press now running, and the activity a press that opened the app reached; null for
     * none. Whatever ends the press ends this call ([end]). */
    private var running: Long? = null
    private var runningIn: java.lang.ref.WeakReference<ExactActivity>? = null

    /** End the running press now, saying [why]: the runner revokes it, and every call it made, its tasks' included, is
     * no longer the person's. */
    private fun end(why: String) {
        val id = running ?: return
        running = null
        runningIn = null
        if (Exact.pressLive(id)) {
            journal("control: press $id ended: $why")
            Exact.cancelPress(id)
        }
    }

    /** A press began as call [id], in [activity] where it opened the app: the screen turning off ends it. */
    private fun began(context: Context, id: Long?, activity: ExactActivity?) {
        running = id ?: return
        runningIn = activity?.let { java.lang.ref.WeakReference(it) }
        val app = context.applicationContext
        val off = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) { if (running == id) end("the screen turned off") }
        }
        val screen = android.content.IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(off, screen, Context.RECEIVER_NOT_EXPORTED) else app.registerReceiver(off, screen)
        main.postDelayed({ app.unregisterReceiver(off) }, BOUND_MS)
    }

    /** A tile was pressed: the press before it ends, and one still waiting for the app is dropped. */
    fun superseded() {
        end("another tile was pressed")
        drop("superseded by another press before the app was ready")
        unlocking.values.forEach { journal("control:${it.kind}: superseded by another press before the unlock") }
        unlocking.clear()
    }

    /** Drop the press waiting, if any, saying [why]. */
    private fun drop(why: String) {
        val earlier = pending ?: issued ?: return
        pending = null
        issued = null
        journal("control:${earlier.kind}: $why")
    }

    /** [activity] stopped: the press running in it ends, and one that reached it and waits is dropped, not run at a
     * later visit. */
    fun stopped(activity: ExactActivity) {
        if (runningIn?.get() === activity) end("the app left the front")
        if (receiver?.get() !== activity) return
        val record = pending ?: return
        pending = null
        journal("control:${record.kind}: the app left the front before the press ran, so it was dropped")
    }

    /** Whether [intent] carried a handoff: taken off it, and kept for [ready] when it names this process's last
     * record. */
    fun receive(activity: ExactActivity, intent: Intent): Boolean {
        val token = intent.getStringExtra(TOKEN) ?: return false
        intent.removeExtra(TOKEN)
        val record = issued?.takeIf { it.token == token }
        if (record != null) issued = null
        when {
            intent.component?.className != ALIAS -> journal("control: a press that did not come through the app's own tile was dropped")
            record == null || record.late() -> journal("control: a press already taken, superseded or from before this process was dropped")
            else -> {
                pending = record
                receiver = java.lang.ref.WeakReference(activity)
                main.postDelayed({ expire(record) }, record.at + BOUND_MS - SystemClock.elapsedRealtime())
                ready(activity)
            }
        }
        return true
    }

    /** Whether [activity] can run a handoff now: resumed, drawn since its start, and unlocked. */
    private fun eligible(activity: ExactActivity) =
        activity.resumedAndDrawn() && activity.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked != true

    /** The activity may now be ready for a handoff: [eligible], its data module active. Checked again when the data
     * answers, and the bound with it. */
    fun ready(activity: ExactActivity) {
        val record = pending ?: return
        if (receiver?.get() !== activity || asking === record || !eligible(activity)) return
        val owner = Exact.owner ?: return
        asking = record
        // On the main thread, as every other change of [pending] is.
        owner.active { ok ->
            if (asking === record) asking = null
            if (pending !== record) return@active
            if (!ok) return@active drop("the app's data did not start, so the press was dropped")
            if (!eligible(activity)) return@active drop("the app left the front before the press ran, so it was dropped")
            if (record.late()) return@active expire(record)
            pending = null
            began(activity, Exact.press(record.kind, record.digest, foreground = true, cold = record.cold, hidden = false), activity)
        }
    }

    private fun expire(record: Record) {
        if (pending !== record) return
        pending = null
        journal("control:${record.kind}: the app was not ready in front within ${BOUND_MS / 1000} s, so the press was dropped")
    }

    /** A tile's press of a tool that runs where it is pressed: in the host that runs, or one booted for it. A session
     * not ready within [BOUND_MS] of the click at [at] ([SystemClock.elapsedRealtime]) drops it. */
    fun press(context: Context, kind: String, digest: String, at: Long, cold: Boolean = !Exact.live) {
        val live = { SystemClock.elapsedRealtime() - at <= BOUND_MS }
        Headless.session(context, live) { ok ->
            if (!ok) {
                android.util.Log.w("exact", "control:$kind: no session ready for the press, or it lapsed")
                return@session
            }
            val hidden = Exact.reader?.get()?.resumedAndDrawn() != true
            began(context, Exact.press(kind, digest, foreground = false, cold = cold, hidden = hidden), null)
        }
    }

    /** A tile press refused before it reached the app. */
    fun refuse(kind: String, why: String) = journal("control:$kind: refused, $why")

    /** A line for the session's journal, or logcat in a process no host runs in yet. */
    private fun journal(line: String) {
        if (Exact.live) Exact.journal(line) else android.util.Log.i("exact", line)
    }
}

/**
 * A locked tile's press of a tool that runs where it is pressed (`required` and `local`): the tile starts this activity
 * once the person unlocks, and it presses and finishes, showing nothing, so the person stays where they were. Where it
 * is made behind the keyguard all the same (the `Intent` overload before API 34 starts it at once), it asks the system
 * to dismiss the keyguard and presses only once it has. Unexported, so only the app's own tile starts it.
 */
class ControlPress : android.app.Activity() {
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(state: android.os.Bundle?) {
        super.onCreate(state)
        val token = intent.getStringExtra(TOKEN)
        if (state != null || token == null) return finish()
        val press = Controls.unlocked(token)
        val keyguard = getSystemService(KeyguardManager::class.java) ?: return finish()
        val pressed = { press(applicationContext); finish() }
        // The device reads locked for a moment after the unlock that started this activity: watched for a while before
        // asking for a dismissal the keyguard, already going, would never answer.
        fun unlocked(left: Int) {
            when {
                !keyguard.isDeviceLocked -> pressed()
                left > 0 -> main.postDelayed({ unlocked(left - 1) }, 100)
                else -> {
                    keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                        override fun onDismissSucceeded() = pressed()
                        override fun onDismissCancelled() = finish()
                        override fun onDismissError() = finish()
                    })
                    main.postDelayed({ if (!isFinishing) finish() }, 20_000)
                }
            }
        }
        unlocked(20)
    }

    internal companion object {
        private const val TOKEN = "dev.exact.control.token"

        fun intent(context: Context, kind: String, digest: String): Intent {
            val token = Controls.unlockPress(kind, digest)
            return Intent(context, ControlPress::class.java).setIdentifier(token)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                .putExtra(TOKEN, token)
        }
    }
}
