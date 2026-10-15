package io.github.mmerioles.drill

import android.app.Application
import android.app.UiModeManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.mmerioles.drill.core.Engine
import io.github.mmerioles.drill.core.EngineState
import io.github.mmerioles.drill.core.FocusRecord
import io.github.mmerioles.drill.core.FocusSession
import io.github.mmerioles.drill.core.Heatmap
import io.github.mmerioles.drill.core.Inspo
import io.github.mmerioles.drill.core.Phase
import io.github.mmerioles.drill.core.Status
import io.github.mmerioles.drill.core.TimerConfig
import io.github.mmerioles.drill.core.Transition
import io.github.mmerioles.drill.data.SessionStore
import io.github.mmerioles.drill.data.Sync
import io.github.mmerioles.drill.data.Updater
import io.github.mmerioles.drill.timer.Notifier
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

class DrillApp : Application() {
    val model by lazy { AppModel(this) }

    override fun onCreate() {
        super.onCreate()
        Notifier.setUp(this)
    }

    companion object {
        fun model(context: Context) = (context.applicationContext as DrillApp).model
    }
}

/** Light or dark, like the mac; dark unless picked. */
enum class Theme { Light, Dark }

/**
 * Everything the screen shows, and the one place the timer changes. The
 * screen, the notification buttons and the phase-end alarm all come through
 * here on the main thread, and every change is saved at once: Android can
 * kill the process mid-focus, and the alarm or the next launch catches up.
 */
class AppModel(private val app: Application) {
    private val prefs: SharedPreferences = app.getSharedPreferences("drill", Context.MODE_PRIVATE)
    /** Work that outlives a screen; failures are logged, not fatal. */
    val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Main.immediate +
            CoroutineExceptionHandler { _, e -> Log.e(TAG, "background work failed", e) },
    )
    private val store = SessionStore(app)
    /** The database, one call at a time, off the main thread. */
    private val disk = Dispatchers.IO.limitedParallelism(1)
    /** Writes still on their way to disk, for [settle]. */
    private val writes = mutableListOf<Job>()
    val deviceID: String = prefs.getString("deviceID", null)
        ?: "android-${UUID.randomUUID().toString().uppercase()}".also { prefs.edit().putString("deviceID", it).apply() }

    val sync = Sync(store, deviceID, prefs, scope, onPulled = ::reload)
    val updater = Updater(app, scope)

    var config by mutableStateOf(loadConfig())
        private set
    var theme by mutableStateOf(runCatching { Theme.valueOf(prefs.getString("theme", "Dark")!!) }.getOrDefault(Theme.Dark))
        private set
    var soundOn by mutableStateOf(prefs.getBoolean("sound", true))
        private set

    private val engine = Engine(config, loadEngine())
    var timer by mutableStateOf(engine.state)
        private set

    var tag by mutableStateOf(prefs.getString("tag", "")!!)
        private set
    /** The tag in effect for the running focus block, captured when it starts. */
    private var blockTag: String? = prefs.getString("blockTag", null)

    /** The sessions the year shows, nothing older. */
    var sessions by mutableStateOf(emptyList<FocusSession>())
        private set
    /** Distinct tags, most recently used first. */
    var recentTags by mutableStateOf(emptyList<String>())
        private set
    /** The year's last day, moved on by [reload]. */
    var today by mutableStateOf(LocalDate.now())
        private set
    var lastError by mutableStateOf<String?>(null)
        private set

    /** YouTube id to the day it was first opened on this phone. */
    var watched by mutableStateOf(loadWatched())
        private set

    init {
        reload()
    }

    // These read the observable [timer] and [config], so whatever draws them
    // updates when either changes.

    fun remaining(now: Long): Long = timer.remaining(config, now)

    fun progress(now: Long): Float {
        val duration = config.duration(timer.phase) * 1000L
        if (duration <= 0) return 0f
        return (1f - remaining(now).toFloat() / duration).coerceIn(0f, 1f)
    }

    val cyclePosition get() = timer.focusCount % config.longBreakEvery
    /** A block is under way, running or paused: no updating now. */
    val isActive get() = timer.status !is Status.Idle

    fun toggle() {
        val now = System.currentTimeMillis()
        val starting = engine.isIdle
        engine.toggle(now)
        if (starting && engine.phase == Phase.Focus) captureTag()
        Notifier.clearEnded(app)
        changed()
    }

    /** The notification's "start break"/"start focus": only if that phase is still waiting. */
    fun startNext(offered: Phase) {
        if (engine.isIdle && engine.phase == offered) toggle()
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
        pinNightMode()
    }

    /** On Android 12+, makes the launch screen (values-night) match the app's theme, not the phone's. */
    fun pinNightMode() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val mode = if (theme == Theme.Dark) UiModeManager.MODE_NIGHT_YES else UiModeManager.MODE_NIGHT_NO
        app.getSystemService(UiModeManager::class.java).setApplicationNightMode(mode)
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

    /** Reads the year and the recent tags again, as of now. */
    fun reload() {
        scope.launch {
            val day = LocalDate.now()
            val from = Heatmap.start(day).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            val loaded = withContext(disk) { runCatching { store.since(from) to store.tags(6) } }
            loaded.onSuccess { (year, tags) ->
                sessions = year
                recentTags = tags
            }.onFailure { Log.e(TAG, "couldn't read sessions", it) }
            today = day
        }
    }

    /** Waits for pending writes and sync, for a receiver keeping the process alive. */
    suspend fun settle() {
        writes.toList().forEach { it.join() }
        sync.settle()
    }

    private fun captureTag() {
        blockTag = tag.trim().lowercase().ifEmpty { null }
    }

    private fun handle(t: Transition) {
        t.record?.let { log(it) }
        if (t.next == Phase.Focus && engine.isRunning) captureTag()
        if (t.natural) {
            Notifier.ended(app, t.finished, t.next, config.duration(t.next), waits = engine.isIdle, sound = soundOn)
        }
    }

    private fun log(record: FocusRecord) {
        val session = FocusSession.from(record, blockTag, deviceID, System.currentTimeMillis())
        // After an alarm, the receiver waits for this (settle): the process may not live long.
        val job = scope.launch {
            val saved = withContext(disk) { runCatching { store.save(listOf(session), local = true) } }
            saved.exceptionOrNull()?.let { Log.e(TAG, "couldn't save a session", it) }
            lastError = if (saved.isSuccess) null else "couldn't save that session."
            reload()
            sync.recount()
            sync.autoSync()
        }
        writes += job
        job.invokeOnCompletion { scope.launch { writes.remove(job) } }
    }

    private fun changed() {
        timer = engine.state
        saveEngine()
        val tagged = blockTag?.takeIf { engine.phase == Phase.Focus }
        Notifier.schedule(app, engine.state, engine.remaining(System.currentTimeMillis()), tagged)
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

    private companion object {
        const val TAG = "drill"
    }
}
