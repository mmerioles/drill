package io.github.mmerioles.drill.core

// Run/walk intervals: the same shape as Engine, with time passed in. Each
// interval's end chains from the last, so a phone asleep through several
// steps through all of them without drift.

enum class IntervalPhase { Run, Walk }

data class IntervalConfig(
    /** Seconds. */
    val run: Int = 5 * 60,
    val walk: Int = 60,
) {
    fun duration(phase: IntervalPhase): Int = if (phase == IntervalPhase.Run) run else walk
}

data class IntervalState(
    val phase: IntervalPhase = IntervalPhase.Run,
    val status: Status = Status.Idle,
    /** Run intervals started so far; 1 after start. */
    val round: Int = 0,
    val startedAt: Long? = null,
    /** Workout ms banked before the last pause. */
    val accrued: Long = 0,
    val runStartedAt: Long? = null,
) {
    fun remaining(config: IntervalConfig, now: Long): Long = when (status) {
        Status.Idle -> config.duration(phase) * 1000L
        is Status.Paused -> status.remaining
        is Status.Running -> maxOf(0, status.endsAt - now)
    }
}

/** A workout worth logging. */
data class WorkoutRecord(val startedAt: Long, val endedAt: Long, val seconds: Double)

data class IntervalTransition(val finished: IntervalPhase, val next: IntervalPhase, val round: Int)

class IntervalEngine(var config: IntervalConfig = IntervalConfig(), var state: IntervalState = IntervalState()) {
    val phase get() = state.phase
    val isRunning get() = state.status is Status.Running
    val isIdle get() = state.status is Status.Idle
    private val duration: Long get() = config.duration(phase) * 1000L

    fun remaining(now: Long): Long = state.remaining(config, now)

    fun start(now: Long) {
        when (val s = state.status) {
            is Status.Running -> return
            Status.Idle -> {
                state = IntervalState(IntervalPhase.Run, round = 1, startedAt = now)
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

    /** Steps through every interval end passed; returns the last transition. */
    fun tick(now: Long): IntervalTransition? {
        var last: IntervalTransition? = null
        while (true) {
            val s = state.status as? Status.Running ?: break
            if (now < s.endsAt) break
            last = advance(s.endsAt)
        }
        return last
    }

    /** Moves to the next interval now; nothing while idle. */
    fun skip(now: Long): IntervalTransition? = if (isIdle) null else advance(now)

    /** Workout time so far, excluding pauses, capped at a day. */
    fun elapsed(now: Long): Long {
        val live = state.runStartedAt?.let { maxOf(0, now - it) } ?: 0
        return minOf(DAY, state.accrued + live)
    }

    /** Ends the workout. A record only when it was long enough to count. */
    fun stop(now: Long): WorkoutRecord? {
        val startedAt = state.startedAt
        val seconds = elapsed(now) / 1000.0
        state = IntervalState()
        if (startedAt == null || seconds < Engine.MINIMUM_LOGGABLE) return null
        return WorkoutRecord(startedAt, now, seconds)
    }

    private fun run(ms: Long, now: Long) {
        state = state.copy(runStartedAt = now, status = Status.Running(now + ms))
    }

    private fun advance(from: Long): IntervalTransition {
        val finished = phase
        val next = if (finished == IntervalPhase.Run) IntervalPhase.Walk else IntervalPhase.Run
        val round = if (next == IntervalPhase.Run) state.round + 1 else state.round
        val length = config.duration(next) * 1000L
        val status = if (state.status is Status.Paused) Status.Paused(length) else Status.Running(from + length)
        state = state.copy(phase = next, round = round, status = status)
        return IntervalTransition(finished, next, round)
    }

    private companion object {
        const val DAY = 24 * 3600 * 1000L
    }
}
