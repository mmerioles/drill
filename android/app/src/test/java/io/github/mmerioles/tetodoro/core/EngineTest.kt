package io.github.mmerioles.tetodoro.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// The same cases as Tests/TetodoroCoreTests/PomodoroEngineTests.swift.
class EngineTest {
    private val t0 = 1_000_000_000L
    private val config = TimerConfig(focus = 100, shortBreak = 10, longBreak = 30, longBreakEvery = 2,
        autoStartBreaks = true, autoStartFocus = false)
    private fun s(seconds: Int) = t0 + seconds * 1000L

    @Test fun countsDownFromWallClock() {
        val e = Engine(config)
        e.start(t0)
        assertEquals(60_000L, e.remaining(s(40)))
        assertNull(e.tick(s(99)))
    }

    @Test fun pauseFreezesRemainingAndExcludesPausedTime() {
        val e = Engine(config)
        e.start(t0)
        e.pause(s(30))
        assertEquals(70_000L, e.remaining(s(500)))
        e.start(s(500))
        val r = e.tick(s(570))!!.record!!
        assertEquals(100.0, r.focusSeconds, 0.0)
        assertEquals(t0, r.startedAt)
        assertEquals(s(570), r.endedAt)
        assertTrue(r.completed)
    }

    @Test fun completedFocusAutoStartsBreakFromNow() {
        val e = Engine(config)
        e.start(t0)
        // Asleep well past the deadline: the break starts at wake, not at t0+100.
        val t = e.tick(s(1000))!!
        assertEquals(Phase.ShortBreak, t.next)
        assertEquals(Status.Running(s(1010)), e.state.status)
        assertNull(e.tick(s(1000)))
    }

    @Test fun everyNthBreakIsLong() {
        val e = Engine(config)
        e.start(t0)
        assertEquals(Phase.ShortBreak, e.tick(s(100))?.next)
        assertEquals(Phase.Focus, e.tick(s(110))?.next)
        assertTrue(e.isIdle) // autoStartFocus is off
        e.start(s(200))
        assertEquals(Phase.LongBreak, e.tick(s(300))?.next)
    }

    @Test fun skippingFocusLogsPartialTimeOnlyAboveMinimum() {
        val e = Engine(TimerConfig(focus = 25 * 60))
        e.start(t0)
        assertNull(e.skip(s(30)).record)

        val f = Engine(TimerConfig(focus = 25 * 60))
        f.start(t0)
        val r = f.skip(s(600)).record!!
        assertEquals(600.0, r.focusSeconds, 0.0)
        assertTrue(!r.completed)
        assertTrue(f.isIdle)
    }

    @Test fun skippedFocusStillCountsTowardsTheLongBreak() {
        val e = Engine(config)
        e.start(t0)
        e.skip(s(10))
        e.skip(s(11)) // the break
        e.start(s(20))
        assertEquals(Phase.LongBreak, e.tick(s(120))?.next)
    }

    @Test fun resetReturnsFocusSpentAndRewinds() {
        val e = Engine(TimerConfig(focus = 25 * 60))
        e.start(t0)
        val r = e.reset(s(120))
        assertNotNull(r)
        assertEquals(120.0, r!!.focusSeconds, 0.0)
        assertTrue(e.isIdle)
        assertEquals(Phase.Focus, e.phase)
        assertEquals(25 * 60_000L, e.remaining(s(500)))
    }
}
