package io.github.mmerioles.drill.core

// The pomodoro state machine, ported from web/static/engine.js (itself from
// DrillCore/PomodoroEngine.swift). Time is passed in as epoch ms, so the
// engine never drifts and survives the app being killed: whoever is awake,
// the screen or the phase-end alarm, calls tick(now) and gets back a
// transition when a phase ended.

enum class Phase {
    Focus, ShortBreak, LongBreak;

    val isBreak get() = this != Focus
}

data class TimerConfig(
    /** Seconds. */
    val focus: Int = 25 * 60,
    val shortBreak: Int = 5 * 60,
    val longBreak: Int = 15 * 60,
    /** A long break replaces every Nth short break. */
    val longBreakEvery: Int = 4,
    val autoStartBreaks: Boolean = true,
    val autoStartFocus: Boolean = false,
) {
    fun duration(phase: Phase): Int = when (phase) {
        Phase.Focus -> focus
        Phase.ShortBreak -> shortBreak
        Phase.LongBreak -> longBreak
    }
}

sealed interface Status {
    data object Idle : Status
    data class Running(val endsAt: Long) : Status
    data class Paused(val remaining: Long) : Status
}

/** Everything the engine knows besides its config; what gets saved. */
data class EngineState(
    val phase: Phase = Phase.Focus,
    val status: Status = Status.Idle,
    val focusCount: Int = 0,
    val blockStartedAt: Long? = null,
    /** Focus ms banked before the current run, i.e. before the last pause. */
    val accrued: Long = 0,
    val runStartedAt: Long? = null,
)

/** A focus block worth logging. */
data class FocusRecord(
    val startedAt: Long,
    val endedAt: Long,
    val focusSeconds: Double,
    val plannedSeconds: Int,
    val completed: Boolean,
)

data class Transition(
    val finished: Phase,
    val next: Phase,
    val record: FocusRecord?,
    /** True when the phase ran out, false when skipped. */
    val natural: Boolean,
)

class Engine(var config: TimerConfig = TimerConfig(), var state: EngineState = EngineState()) {
    val phase get() = state.phase
    val isRunning get() = state.status is Status.Running
    val isIdle get() = state.status is Status.Idle
    val isPaused get() = state.status is Status.Paused
    val duration: Long get() = config.duration(phase) * 1000L
    val cyclePosition get() = state.focusCount % config.longBreakEvery

    /** When the running phase ends, or null. */
    val endsAt get() = (state.status as? Status.Running)?.endsAt

    fun remaining(now: Long): Long = when (val s = state.status) {
        Status.Idle -> duration
        is Status.Paused -> s.remaining
        is Status.Running -> maxOf(0, s.endsAt - now)
    }

    fun progress(now: Long): Float {
        if (duration <= 0) return 0f
        return (1f - remaining(now).toFloat() / duration).coerceIn(0f, 1f)
    }

    // Controls

    fun start(now: Long) {
        when (val s = state.status) {
            is Status.Running -> return
            Status.Idle -> {
                state = state.copy(blockStartedAt = now, accrued = 0)
                run(duration, now)
            }
            is Status.Paused -> run(s.remaining, now)
        }
    }

    fun pause(now: Long) {
        val s = state.status as? Status.Running ?: return
        state = state.copy(
            accrued = state.accrued + (now - (state.runStartedAt ?: now)),
            runStartedAt = null,
            status = Status.Paused(maxOf(0, s.endsAt - now)),
        )
    }

    fun toggle(now: Long) = if (isRunning) pause(now) else start(now)

    /** Advances the clock. Returns a transition if the running phase hit zero. */
    fun tick(now: Long): Transition? {
        val s = state.status as? Status.Running ?: return null
        if (now < s.endsAt) return null
        return finish(s.endsAt, natural = true, now)
    }

    /** Ends the current phase early and moves to the next one, left idle. */
    fun skip(now: Long): Transition = finish(now, natural = false, now)

    /** Rewinds the current phase. Focus already spent is still returned. */
    fun reset(now: Long): FocusRecord? {
        val record = if (phase == Phase.Focus) record(now, completed = false) else null
        clear()
        return record
    }

    // Internals

    private fun run(ms: Long, now: Long) {
        state = state.copy(runStartedAt = now, status = Status.Running(now + ms))
    }

    private fun elapsed(at: Long): Long {
        val live = state.runStartedAt?.let { maxOf(0, at - it) } ?: 0
        return minOf(duration, state.accrued + live)
    }

    private fun record(endedAt: Long, completed: Boolean): FocusRecord? {
        val startedAt = state.blockStartedAt ?: return null
        val focused = elapsed(endedAt) / 1000.0
        if (!completed && focused < MINIMUM_LOGGABLE) return null
        return FocusRecord(startedAt, endedAt, focused, config.focus, completed)
    }

    private fun clear() {
        state = state.copy(blockStartedAt = null, runStartedAt = null, accrued = 0, status = Status.Idle)
    }

    private fun finish(endedAt: Long, natural: Boolean, now: Long): Transition {
        val finished = phase
        var record: FocusRecord? = null

        if (finished == Phase.Focus) {
            record = record(endedAt, natural)
            // A skipped focus block still counts as a round, so skipping keeps
            // building towards the long break like any pomodoro timer.
            val count = state.focusCount + 1
            val longDue = count % config.longBreakEvery == 0
            state = state.copy(focusCount = count, phase = if (longDue) Phase.LongBreak else Phase.ShortBreak)
        } else {
            state = state.copy(phase = Phase.Focus)
        }
        clear()

        // Auto-started phases begin now, not at the old deadline, so a phone
        // asleep through several phases wakes to one transition.
        val auto = if (phase.isBreak) config.autoStartBreaks else config.autoStartFocus
        if (natural && auto) start(now)

        return Transition(finished, phase, record, natural)
    }

    companion object {
        /** Cut-short focus blocks shorter than this aren't worth logging. */
        const val MINIMUM_LOGGABLE = 60
    }
}
