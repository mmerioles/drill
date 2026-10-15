package io.github.mmerioles.drill.core

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters
import java.time.temporal.WeekFields
import java.util.Locale

// Days in week columns, a port of web/static/heatmap.js. Local time zone;
// weeks start on the locale's first weekday.

data class Day(val date: LocalDate, val seconds: Double, val level: Int)

data class Heatmap(
    /** weeks[column][row]; row 0 is the first weekday. Null for days still to come. */
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

        fun firstWeekday(locale: Locale = Locale.getDefault()): DayOfWeek = WeekFields.of(locale).firstDayOfWeek

        /** The first day a grid of [weeks] columns shows, for loading just that much. */
        fun start(today: LocalDate, weeks: Int = MAX_WEEKS, firstDay: DayOfWeek = firstWeekday()): LocalDate =
            today.with(TemporalAdjusters.previousOrSame(firstDay)).minusWeeks((weeks - 1).toLong())

        /** The widest grid, a year; a narrow phone shows the last half of it. */
        const val MAX_WEEKS = 53

        fun build(
            sessions: List<FocusSession>,
            weeks: Int,
            today: LocalDate = LocalDate.now(),
            zone: ZoneId = ZoneId.systemDefault(),
            firstDay: DayOfWeek = firstWeekday(),
        ): Heatmap {
            val totals = HashMap<LocalDate, Double>()
            for (s in sessions) {
                val day = Instant.ofEpochMilli(s.startedAt).atZone(zone).toLocalDate()
                totals[day] = (totals[day] ?: 0.0) + s.focusSeconds
            }

            val weekStart = today.with(TemporalAdjusters.previousOrSame(firstDay))
            val gridStart = start(today, weeks, firstDay)
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
