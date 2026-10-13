package io.github.mmerioles.drill.core

import kotlin.math.roundToInt

// Sentences shared by the screen and the notifications, as in
// DrillApp/Copy.swift. Lowercase, short, kind.

object Copy {
    /** The banner when a phase runs out. [nextSeconds] is the length of the
     *  phase that follows, for "take a break · 5 min". */
    fun finished(phase: Phase, nextSeconds: Int): Pair<String, String> {
        val minutes = maxOf(1, (nextSeconds / 60.0).roundToInt())
        return if (phase == Phase.Focus) "focus done" to "take a break · $minutes min"
        else "break over" to "back to focus"
    }

    /** The banner's one action, when the next phase won't start by itself. */
    fun startNext(next: Phase) = if (next.isBreak) "start break" else "start focus"

    /** The ring's spoken name: the phase, whether or not it's running. */
    fun phaseName(phase: Phase) = when (phase) {
        Phase.Focus -> "focus"
        Phase.ShortBreak -> "break"
        Phase.LongBreak -> "long break"
    }

    /** What TalkBack says for the countdown: "12 minutes left". */
    fun spokenLeft(ms: Long): String {
        val total = ((ms + 999) / 1000).toInt()
        if (total >= 60) {
            val m = (total + 59) / 60
            return if (m == 1) "1 minute left" else "$m minutes left"
        }
        return if (total == 1) "1 second left" else "$total seconds left"
    }

    /** How long until the displayed second changes, for a countdown with
     *  [remaining] ms left: one wake a second, on the boundary, so no digit
     *  is skipped or doubled and nothing drifts over a long block. */
    fun untilNextSecond(remaining: Long): Long =
        if (remaining <= 0) 0 else (remaining - 1) % 1000 + 1
}
