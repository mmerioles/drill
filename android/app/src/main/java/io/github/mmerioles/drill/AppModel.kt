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
import io.github.mmerioles.drill.core.Copy
import io.github.mmerioles.drill.core.Engine
import io.github.mmerioles.drill.core.EngineState
import io.github.mmerioles.drill.core.FocusRecord
import io.github.mmerioles.drill.core.FocusSession
import io.github.mmerioles.drill.core.Heatmap
import io.github.mmerioles.drill.core.Inspo
import io.github.mmerioles.drill.core.IntervalConfig
import io.github.mmerioles.drill.core.IntervalEngine
import io.github.mmerioles.drill.core.IntervalPhase
import io.github.mmerioles.drill.core.IntervalState
import io.github.mmerioles.drill.core.IntervalTransition
import io.github.mmerioles.drill.core.Phase
import io.github.mmerioles.drill.core.Status
import io.github.mmerioles.drill.core.TimerConfig
import io.github.mmerioles.drill.core.Transition
import io.github.mmerioles.drill.core.WorkoutRecord
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

/** Which timer the clock shows; a tap on it switches, between blocks. */
enum class Mode { Pomodoro, Intervals }

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

    var mode by mutableStateOf(runCatching { Mode.valueOf(prefs.getString("mode", "Pomodoro")!!) }.getOrDefault(Mode.Pomodoro))
        private set
    var intervalConfig by mutableStateOf(IntervalConfig(run = prefs.getInt("run", 5 * 60), walk = prefs.getInt("walk", 60)))
        private set
    private val intervals = IntervalEngine(intervalConfig, loadIntervals())
    var workout by mutableStateOf(intervals.state)
        private set
    val isIntervals get() = mode == Mode.Intervals

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

    /** The mode's timer, whichever it is. */
    val status: Status get() = if (isIntervals) workout.status else timer.status

    fun remaining(now: Long): Long =
        if (isIntervals) workout.remaining(intervalConfig, now) else timer.remaining(config, now)

    fun progress(now: Long): Float {
        val duration = (if (isIntervals) intervalConfig.duration(workout.phase) else config.duration(timer.phase)) * 1000L
        if (duration <= 0) return 0f
        return (1f - remaining(now).toFloat() / duration).coerceIn(0f, 1f)
    }

    /** Workout seconds so far, for "round 3 · 18m". */
    fun elapsed(now: Long): Double = intervals.elapsed(now) / 1000.0

    val cyclePosition get() = timer.focusCount % config.longBreakEvery
    /** A block is under way, running or paused: no updating now. */
    val isActive get() = status !is Status.Idle

    fun toggle() {
        val now = System.currentTimeMillis()
        if (isIntervals) {
            intervals.toggle(now)
        } else {
            val starting = engine.isIdle
            engine.toggle(now)
            if (starting && engine.phase == Phase.Focus) captureTag()
        }
        Notifier.clearEnded(app)
        changed()
    }

    /** Only between blocks, so switching never drops time. */
    fun switchMode() {
        if (isActive) return
        mode = if (isIntervals) Mode.Pomodoro else Mode.Intervals
        prefs.edit().putString("mode", mode.name).apply()
        changed()
    }

    /** The notification's "start break"/"start focus": only if that phase is still waiting. */
    fun startNext(offered: Phase) {
        if (!isIntervals && engine.isIdle && engine.phase == offered) toggle()
    }

    fun skip() {
        val now = System.currentTimeMillis()
        if (isIntervals) intervals.skip(now)?.let(::cue) else handle(engine.skip(now))
        changed()
    }

    /** Pomodoro: rewind the phase. Intervals: "done", the workout is over and logged. */
    fun reset() {
        val now = System.currentTimeMillis()
        if (isIntervals) intervals.stop(now)?.let(::log) else engine.reset(now)?.let { log(it) }
        changed()
    }

    /** A phase may have ended while nobody was looking. */
    fun catchUp() {
        val now = System.currentTimeMillis()
        if (isIntervals) intervals.tick(now)?.let(::cue) else engine.tick(now)?.let(::handle)
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

    fun updateIntervals(c: IntervalConfig) {
        intervalConfig = c
        intervals.config = c
        prefs.edit().putInt("run", c.run).putInt("walk", c.walk).apply()
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

    /** Buzz, chime and say which interval is next; the same whether it ran out or was skipped. */
    private fun cue(t: IntervalTransition) {
        Notifier.vibrate(app, t.next)
        val minutes = maxOf(1, Math.round(intervalConfig.duration(t.next) / 60.0).toInt())
        Notifier.ended(app, Copy.intervalName(t.next, t.round), "$minutes min", sound = soundOn)
    }

    /** A workout is an ordinary session tagged "intervals". */
    private fun log(record: WorkoutRecord) {
        val seconds = Math.round(record.seconds).toInt()
        log(FocusRecord(record.startedAt, record.endedAt, record.seconds, seconds, completed = true), "intervals")
    }

    private fun log(record: FocusRecord, tag: String? = blockTag) {
        val session = FocusSession.from(record, tag, deviceID, System.currentTimeMillis())
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
        workout = intervals.state
        saveEngine()
        val now = System.currentTimeMillis()
        if (isIntervals) {
            Notifier.schedule(app, workout.status, Copy.intervalName(workout.phase, workout.round), remaining(now), stop = "done")
        } else {
            val tagged = blockTag?.takeIf { engine.phase == Phase.Focus }
            val name = Copy.phaseName(engine.phase) + (tagged?.let { " · $it" } ?: "")
            Notifier.schedule(app, timer.status, name, remaining(now))
        }
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
        val w = intervals.state
        prefs.edit()
            .putString("engine.phase", s.phase.name)
            .putString("engine.status", s.status.kind)
            .putLong("engine.statusValue", s.status.value)
            .putInt("engine.focusCount", s.focusCount)
            .putLong("engine.blockStartedAt", s.blockStartedAt ?: -1)
            .putLong("engine.accrued", s.accrued)
            .putLong("engine.runStartedAt", s.runStartedAt ?: -1)
            .putString("blockTag", blockTag)
            .putString("intervals.phase", w.phase.name)
            .putString("intervals.status", w.status.kind)
            .putLong("intervals.statusValue", w.status.value)
            .putInt("intervals.round", w.round)
            .putLong("intervals.startedAt", w.startedAt ?: -1)
            .putLong("intervals.accrued", w.accrued)
            .putLong("intervals.runStartedAt", w.runStartedAt ?: -1)
            .apply()
    }

    private val Status.kind get() = when (this) {
        Status.Idle -> "idle"
        is Status.Running -> "running"
        is Status.Paused -> "paused"
    }

    private val Status.value get() = when (this) {
        Status.Idle -> 0L
        is Status.Running -> endsAt
        is Status.Paused -> remaining
    }

    private fun loadStatus(prefix: String): Status {
        val value = prefs.getLong("$prefix.statusValue", 0)
        return when (prefs.getString("$prefix.status", "idle")) {
            "running" -> Status.Running(value)
            "paused" -> Status.Paused(value)
            else -> Status.Idle
        }
    }

    private fun optional(key: String) = prefs.getLong(key, -1).takeIf { it >= 0 }

    private fun loadIntervals() = IntervalState(
        phase = runCatching { IntervalPhase.valueOf(prefs.getString("intervals.phase", "Run")!!) }.getOrDefault(IntervalPhase.Run),
        status = loadStatus("intervals"),
        round = prefs.getInt("intervals.round", 0),
        startedAt = optional("intervals.startedAt"),
        accrued = prefs.getLong("intervals.accrued", 0),
        runStartedAt = optional("intervals.runStartedAt"),
    )

    private fun loadEngine() = EngineState(
        phase = runCatching { Phase.valueOf(prefs.getString("engine.phase", "Focus")!!) }.getOrDefault(Phase.Focus),
        status = loadStatus("engine"),
        focusCount = prefs.getInt("engine.focusCount", 0),
        blockStartedAt = optional("engine.blockStartedAt"),
        accrued = prefs.getLong("engine.accrued", 0),
        runStartedAt = optional("engine.runStartedAt"),
    )

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
