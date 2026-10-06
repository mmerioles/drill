package io.github.mmerioles.tetodoro.core

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

// A stretch of days in week columns, ported from web/static/heatmap.js.
// Days are bucketed in the phone's own time zone, and weeks start on Sunday.

data class Day(val date: LocalDate, val seconds: Double, val level: Int)

data class Heatmap(
    /** weeks[column][row]; row 0 is Sunday. Null for days still to come. */
    val weeks: List<List<Day?>>,
    val today: Double,
    val thisWeek: Double,
    val streak: Int,
) {
    companion object {
        /** Intensity 0–4. Fixed thresholds, so a cell means the same thing next year. */
        fun level(seconds: Double): Int = when {
            seconds < 60 -> 0
            seconds < 30 * 60 -> 1
            seconds < 90 * 60 -> 2
            seconds < 180 * 60 -> 3
            else -> 4
        }

        fun build(
            sessions: List<FocusSession>,
            weeks: Int,
            today: LocalDate = LocalDate.now(),
            zone: ZoneId = ZoneId.systemDefault(),
        ): Heatmap {
            val totals = HashMap<LocalDate, Double>()
            for (s in sessions) {
                val day = Instant.ofEpochMilli(s.startedAt).atZone(zone).toLocalDate()
                totals[day] = (totals[day] ?: 0.0) + s.focusSeconds
            }

            val weekStart = today.with(TemporalAdjusters.previousOrSame(DayOfWeek.SUNDAY))
            val gridStart = weekStart.minusWeeks((weeks - 1).toLong())
            val columns = List(weeks) { w ->
                List(7) { d ->
                    val date = gridStart.plusDays((w * 7 + d).toLong())
                    if (date.isAfter(today)) null
                    else (totals[date] ?: 0.0).let { Day(date, it, level(it)) }
                }
            }

            val thisWeek = totals.filterKeys { !it.isBefore(weekStart) }.values.sum()

            // A streak isn't broken before today's session has happened.
            var streak = 0
            var cursor = today
            if ((totals[cursor] ?: 0.0) <= 0) cursor = cursor.minusDays(1)
            while ((totals[cursor] ?: 0.0) > 0) {
                streak += 1
                cursor = cursor.minusDays(1)
            }

            return Heatmap(columns, totals[today] ?: 0.0, thisWeek, streak)
        }
    }
}
