package io.github.mmerioles.drill.core

import io.github.mmerioles.drill.data.SyncApi
import io.github.mmerioles.drill.data.Updater
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Locale

class StatsTest {
    private val utc: ZoneId = ZoneOffset.UTC

    private fun session(day: LocalDate, minutes: Int, tag: String? = null) = FocusSession(
        id = "$day-$minutes", startedAt = day.atTime(9, 0).toInstant(ZoneOffset.UTC).toEpochMilli(),
        endedAt = 0, focusSeconds = minutes * 60.0, plannedSeconds = 1500.0, completed = true,
        tag = tag, deviceID = "test", updatedAt = 0,
    )

    @Test fun heatmapBucketsDaysAndCountsStreaks() {
        val today = LocalDate.of(2026, 10, 7) // a wednesday
        val sessions = listOf(
            session(today, 25), session(today, 50),
            session(today.minusDays(1), 30),
            session(today.minusDays(2), 10),
            session(today.minusDays(3), 200),
            session(today.minusDays(5), 45), // last week
        )
        val heat = Heatmap.build(sessions, weeks = 26, today = today, zone = utc, firstDay = DayOfWeek.SUNDAY)
        assertEquals(26, heat.weeks.size)
        assertEquals(75 * 60.0, heat.today, 0.0)
        assertEquals(4, heat.streak)
        // The week starts on sunday the 4th: today, tuesday, monday and sunday.
        assertEquals((75 + 30 + 10 + 200) * 60.0, heat.thisWeek, 0.0)
        val last = heat.weeks.last()
        assertEquals(LocalDate.of(2026, 10, 4), last[0]!!.date)
        assertEquals(4, last[0]!!.level)
        assertNull(last[4]) // thursday hasn't happened
    }

    @Test fun streakSurvivesTodayBeforeTheFirstSession() {
        val today = LocalDate.of(2026, 10, 7)
        val heat = Heatmap.build(listOf(session(today.minusDays(1), 30)), 26, today, utc)
        assertEquals(1, heat.streak)
    }

    @Test fun weeksStartOnTheLocalesFirstWeekday() {
        assertEquals(DayOfWeek.SUNDAY, Heatmap.firstWeekday(Locale.US))
        assertEquals(DayOfWeek.MONDAY, Heatmap.firstWeekday(Locale.GERMANY))
        val today = LocalDate.of(2026, 10, 7) // a wednesday
        val sessions = listOf(session(LocalDate.of(2026, 10, 4), 30), session(today, 10)) // sunday, today
        val heat = Heatmap.build(sessions, 26, today, utc, firstDay = DayOfWeek.MONDAY)
        // Monday the 5th starts the week, so sunday's half hour is last week's.
        assertEquals(LocalDate.of(2026, 10, 5), heat.weeks.last()[0]!!.date)
        assertEquals(10 * 60.0, heat.thisWeek, 0.0)
        assertEquals(LocalDate.of(2026, 10, 4), heat.weeks[heat.weeks.size - 2][6]!!.date)
    }

    @Test fun theYearLoadsFromTheGridsFirstDay() {
        val today = LocalDate.of(2026, 10, 7)
        assertEquals(LocalDate.of(2025, 10, 6), Heatmap.start(today, 53, DayOfWeek.MONDAY))
        assertEquals(LocalDate.of(2025, 10, 5), Heatmap.start(today, 53, DayOfWeek.SUNDAY))
        // The 26-week grid is the tail of the loaded year.
        assertEquals(
            Heatmap.start(today, 26, DayOfWeek.MONDAY),
            Heatmap.build(emptyList(), 26, today, utc, DayOfWeek.MONDAY).weeks.first()[0]!!.date,
        )
    }

    @Test fun phaseEndCopy() {
        assertEquals("focus done" to "take a break · 5 min", Copy.finished(Phase.Focus, 5 * 60))
        assertEquals("focus done" to "take a break · 15 min", Copy.finished(Phase.Focus, 15 * 60))
        assertEquals("break over" to "back to focus", Copy.finished(Phase.ShortBreak, 25 * 60))
        assertEquals("start break", Copy.startNext(Phase.LongBreak))
        assertEquals("start focus", Copy.startNext(Phase.Focus))
    }

    @Test fun spokenCountdown() {
        assertEquals("12 minutes left", Copy.spokenLeft(11 * 60_000L + 1))
        assertEquals("1 minute left", Copy.spokenLeft(60_000L))
        assertEquals("1 second left", Copy.spokenLeft(400))
        assertEquals("30 seconds left", Copy.spokenLeft(30_000))
    }

    @Test fun ticksLandOnTheSecond() {
        assertEquals(1000, Copy.untilNextSecond(5000)) // 00:05 shows until 4000 left
        assertEquals(250, Copy.untilNextSecond(4250))
        assertEquals(1, Copy.untilNextSecond(4001))
        assertEquals(0, Copy.untilNextSecond(0))
        // After waiting, the shown second has just changed.
        val left = 7_340L
        val after = left - Copy.untilNextSecond(left)
        assertEquals(7, (after + 999) / 1000)
    }

    @Test fun levelsUseFixedThresholds() {
        assertEquals(listOf(0, 1, 2, 3, 4), listOf(30.0, 60.0, 1800.0, 5400.0, 10800.0).map(Heatmap::level))
    }

    @Test fun inspoShuffleMatchesSwiftAndWeb() {
        // Values from Inspo.swift and inspo.js for the same seed.
        val next = Inspo.mulberry32(20260928)
        assertEquals(listOf(4041811386u, 937448118u, 2916864140u, 1575895958u), List(4) { next() })
        assertEquals(
            listOf("N4JV4wihKI4", "a568Txh1CJU", "FQMX48sgMMQ", "hySSRHwTiIM", "Yh-ctq-dS4s"),
            Inspo.today(emptySet(), on = 20260928).map { it.youtube },
        )
        val seen = setOf("N4JV4wihKI4")
        assertFalse(Inspo.today(seen, on = 20260928).any { it.youtube in seen })
        assertEquals(20260928, Inspo.day(LocalDate.of(2026, 9, 28)))
    }

    @Test fun wireDatesAreWholeSecondUtc() {
        assertEquals("2026-09-26T13:00:00Z", WireDate.format(WireDate.parse("2026-09-26T13:00:00.750Z")))
        assertEquals(WireDate.parse("2026-09-26T13:00:00Z"), WireDate.parse("2026-09-26T15:00:00+02:00"))
    }

    @Test fun sameBlockGetsTheSameId() {
        val r = FocusRecord(1000, 2000, 1.0, 1500, true)
        val a = FocusSession.from(r, null, "android-1", 5)
        val b = FocusSession.from(r, "x", "android-1", 9)
        assertEquals(a.id, b.id)
        assertEquals(a.id, a.id.uppercase())
    }

    @Test fun serverAddresses() {
        assertEquals("https://sync.example.com", SyncApi.serverUrl(" sync.example.com/ "))
        assertEquals("http://192.168.1.4:8080", SyncApi.serverUrl("http://192.168.1.4:8080"))
        assertNull(SyncApi.serverUrl("ftp://example.com"))
        assertNull(SyncApi.serverUrl("   "))
    }

    @Test fun versions() {
        assertTrue(Updater.isNewer("0.10.0", "0.9.3"))
        assertFalse(Updater.isNewer("0.9.3", "0.9.3"))
        assertFalse(Updater.isNewer("0.9.2", "0.9.3"))
        assertTrue(Updater.isNewer("1.0.0", "dev"))
    }
}
