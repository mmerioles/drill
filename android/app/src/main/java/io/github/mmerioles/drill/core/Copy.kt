package io.github.mmerioles.drill.core

import kotlin.math.roundToInt

// Words shared by the screen and the notifications, as in DrillApp/Copy.swift.

object Copy {
    /** "25:00", or "1:05:00" past an hour. Rounds up, so 0:00 means done. */
    fun clock(ms: Long): String {
        val total = ((ms + 999) / 1000).toInt()
        val h = total / 3600
        val m = total % 3600 / 60
        val s = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
    }

    /** "45m", "2h", "1h 30m". */
    fun amount(seconds: Double): String {
        val minutes = (seconds / 60).toInt()
        val h = minutes / 60
        val m = minutes % 60
        return when {
            h == 0 -> "${m}m"
            m == 0 -> "${h}h"
            else -> "${h}h ${m}m"
        }
    }

    fun days(n: Int) = if (n == 1) "1 day" else "$n days"

    /** Title and body when a phase runs out; [nextSeconds] is the next phase's length. */
    fun finished(phase: Phase, nextSeconds: Int): Pair<String, String> {
        val minutes = maxOf(1, (nextSeconds / 60.0).roundToInt())
        return if (phase == Phase.Focus) "focus done" to "take a break · $minutes min"
        else "break over" to "back to focus"
    }

    /** The banner's one action, when the next phase won't start by itself. */
    fun startNext(next: Phase) = if (next.isBreak) "start break" else "start focus"

    fun phaseName(phase: Phase) = when (phase) {
        Phase.Focus -> "focus"
        Phase.ShortBreak -> "break"
        Phase.LongBreak -> "long break"
    }

    fun phaseName(phase: IntervalPhase) = if (phase == IntervalPhase.Run) "run" else "walk"

    /** The interval's notification title: "run · round 3" or "walk". */
    fun intervalName(phase: IntervalPhase, round: Int) =
        if (phase == IntervalPhase.Run) "run · round $round" else "walk"

    /** "round 3 · 18m", under the clock. */
    fun workout(round: Int, seconds: Double) = "round $round · ${amount(seconds)}"

    fun modeName(intervals: Boolean) = if (intervals) "intervals" else "pomodoro"

    /** What TalkBack says for the countdown: "12 minutes left". */
    fun spokenLeft(ms: Long): String {
        val total = ((ms + 999) / 1000).toInt()
        if (total >= 60) {
            val m = (total + 59) / 60
            return if (m == 1) "1 minute left" else "$m minutes left"
        }
        return if (total == 1) "1 second left" else "$total seconds left"
    }

    /** Ms until the shown second changes, so a once-a-second tick lands on the
     *  boundary and never skips or doubles a digit. */
    fun untilNextSecond(remaining: Long): Long =
        if (remaining <= 0) 0 else (remaining - 1) % 1000 + 1
}
