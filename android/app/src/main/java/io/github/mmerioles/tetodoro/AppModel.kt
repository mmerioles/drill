package io.github.mmerioles.tetodoro

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.mmerioles.tetodoro.core.Engine
import io.github.mmerioles.tetodoro.core.EngineState
import io.github.mmerioles.tetodoro.core.FocusRecord
import io.github.mmerioles.tetodoro.core.FocusSession
import io.github.mmerioles.tetodoro.core.Inspo
import io.github.mmerioles.tetodoro.core.Phase
import io.github.mmerioles.tetodoro.core.Status
import io.github.mmerioles.tetodoro.core.TimerConfig
import io.github.mmerioles.tetodoro.core.Transition
import io.github.mmerioles.tetodoro.data.SessionStore
import io.github.mmerioles.tetodoro.data.Sync
import io.github.mmerioles.tetodoro.timer.Notifier
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

class TetodoroApp : Application() {
    val model by lazy { AppModel(this) }

    override fun onCreate() {
        super.onCreate()
        Notifier.setUp(this)
    }

    companion object {
        fun model(context: Context) = (context.applicationContext as TetodoroApp).model
    }
}

enum class Theme { Auto, Light, Dark }

/**
 * Everything the screen shows, and the one place the timer changes. The
 * screen and the phase-end alarm both come through here, on the main thread,
 * and every change is saved at once, so the app can be killed at any time.
 */
class AppModel(private val app: Application) {
    private val prefs: SharedPreferences = app.getSharedPreferences("tetodoro", Context.MODE_PRIVATE)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val store = SessionStore(app)
    val deviceID: String = prefs.getString("deviceID", null)
        ?: "android-${UUID.randomUUID().toString().uppercase()}".also { prefs.edit().putString("deviceID", it).apply() }

    val sync = Sync(store, deviceID, prefs, scope, onPulled = ::reload)

    var config by mutableStateOf(loadConfig())
        private set
    var theme by mutableStateOf(runCatching { Theme.valueOf(prefs.getString("theme", "Auto")!!) }.getOrDefault(Theme.Auto))
        private set
    var soundOn by mutableStateOf(prefs.getBoolean("sound", true))
        private set

    private val engine = Engine(config, loadEngine())
    /** The engine's state, observable. */
    var timer by mutableStateOf(engine.state)
        private set

    /** What the tag field says. */
    var tag by mutableStateOf(prefs.getString("tag", "")!!)
        private set
    /** The tag in effect for the running focus block, captured when it starts. */
    private var blockTag: String? = prefs.getString("blockTag", null)

    var sessions by mutableStateOf(emptyList<FocusSession>())
        private set

    /** YouTube id to the day it was first opened on this phone. */
    var watched by mutableStateOf(loadWatched())
        private set

    init {
        reload()
    }

    // Reading the timer

    fun remaining(now: Long) = engine.remaining(now)
    fun progress(now: Long) = engine.progress(now)
    val cyclePosition get() = timer.focusCount % config.longBreakEvery

    // Intents

    fun toggle() {
        val now = System.currentTimeMillis()
        val starting = engine.isIdle
        engine.toggle(now)
        if (starting && engine.phase == Phase.Focus) captureTag()
        Notifier.clearEnded(app)
        changed()
    }

    fun skip() {
        handle(engine.skip(System.currentTimeMillis()))
        changed()
    }

    fun reset() {
        engine.reset(System.currentTimeMillis())?.let { log(it) }
        changed()
    }

    /** A phase may have ended while nobody was looking. */
    fun catchUp() {
        engine.tick(System.currentTimeMillis())?.let(::handle)
        changed()
    }

    fun updateTag(text: String) {
        tag = text.take(40)
        prefs.edit().putString("tag", tag).apply()
    }

    fun updateConfig(c: TimerConfig) {
        config = c
        engine.config = c
        prefs.edit()
            .putInt("focus", c.focus).putInt("shortBreak", c.shortBreak).putInt("longBreak", c.longBreak)
            .putInt("longBreakEvery", c.longBreakEvery)
            .putBoolean("autoStartBreaks", c.autoStartBreaks).putBoolean("autoStartFocus", c.autoStartFocus)
            .apply()
        changed()
    }

    fun updateTheme(t: Theme) {
        theme = t
        prefs.edit().putString("theme", t.name).apply()
    }

    fun updateSound(on: Boolean) {
        soundOn = on
        prefs.edit().putBoolean("sound", on).apply()
    }

    fun markWatched(video: Inspo.Video) {
        if (video.youtube in watched) return
        watched = watched + (video.youtube to Inspo.day())
        prefs.edit().putStringSet("inspo.seen", watched.map { (id, day) -> "$id:$day" }.toSet()).apply()
    }

    /** Distinct tags, most recently used first. */
    fun tags(limit: Int = 6): List<String> =
        sessions.asReversed().mapNotNull { it.tag }.distinct().take(limit)

    fun reload() {
        scope.launch { sessions = withContext(Dispatchers.IO) { store.live() } }
    }

    // Internals

    private fun captureTag() {
        blockTag = tag.trim().lowercase().ifEmpty { null }
    }

    private fun handle(t: Transition) {
        t.record?.let { log(it) }
        if (t.next == Phase.Focus && engine.isRunning) captureTag()
        if (t.natural) Notifier.ended(app, t.finished, soundOn)
    }

    private fun log(record: FocusRecord) {
        val session = FocusSession.from(record, blockTag, deviceID, System.currentTimeMillis())
        // Written at once: after an alarm, the process may not live long.
        store.save(listOf(session), local = true)
        reload()
        sync.syncNow()
    }

    private fun changed() {
        timer = engine.state
        saveEngine()
        Notifier.schedule(app, engine.endsAt, engine.phase)
    }

    private fun loadConfig() = TimerConfig(
        focus = prefs.getInt("focus", 25 * 60),
        shortBreak = prefs.getInt("shortBreak", 5 * 60),
        longBreak = prefs.getInt("longBreak", 15 * 60),
        longBreakEvery = prefs.getInt("longBreakEvery", 4),
        autoStartBreaks = prefs.getBoolean("autoStartBreaks", true),
        autoStartFocus = prefs.getBoolean("autoStartFocus", false),
    )

    private fun saveEngine() {
        val s = engine.state
        prefs.edit()
            .putString("engine.phase", s.phase.name)
            .putString("engine.status", when (s.status) {
                Status.Idle -> "idle"
                is Status.Running -> "running"
                is Status.Paused -> "paused"
            })
            .putLong("engine.statusValue", when (val st = s.status) {
                Status.Idle -> 0
                is Status.Running -> st.endsAt
                is Status.Paused -> st.remaining
            })
            .putInt("engine.focusCount", s.focusCount)
            .putLong("engine.blockStartedAt", s.blockStartedAt ?: -1)
            .putLong("engine.accrued", s.accrued)
            .putLong("engine.runStartedAt", s.runStartedAt ?: -1)
            .putString("blockTag", blockTag)
            .apply()
    }

    private fun loadEngine(): EngineState {
        val value = prefs.getLong("engine.statusValue", 0)
        fun optional(key: String) = prefs.getLong(key, -1).takeIf { it >= 0 }
        return EngineState(
            phase = runCatching { Phase.valueOf(prefs.getString("engine.phase", "Focus")!!) }.getOrDefault(Phase.Focus),
            status = when (prefs.getString("engine.status", "idle")) {
                "running" -> Status.Running(value)
                "paused" -> Status.Paused(value)
                else -> Status.Idle
            },
            focusCount = prefs.getInt("engine.focusCount", 0),
            blockStartedAt = optional("engine.blockStartedAt"),
            accrued = prefs.getLong("engine.accrued", 0),
            runStartedAt = optional("engine.runStartedAt"),
        )
    }

    private fun loadWatched(): Map<String, Int> =
        prefs.getStringSet("inspo.seen", emptySet())!!.mapNotNull { entry ->
            val i = entry.lastIndexOf(':')
            val day = entry.substring(i + 1).toIntOrNull()
            if (i <= 0 || day == null) null else entry.substring(0, i) to day
        }.toMap()
}
