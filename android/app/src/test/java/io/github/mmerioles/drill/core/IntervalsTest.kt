package io.github.mmerioles.drill.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// The spec's vectors, the same on every platform: run 300, walk 60.
class IntervalsTest {
    private val t0 = 1_000_000_000L
    private fun s(seconds: Int) = t0 + seconds * 1000L
    private fun started() = IntervalEngine(IntervalConfig(run = 300, walk = 60)).apply { start(t0) }

    @Test fun startsARunRoundOne() {
        val e = started()
        assertEquals(IntervalPhase.Run, e.phase)
        assertEquals(1, e.state.round)
        assertEquals(Status.Running(s(300)), e.state.status)
    }

    @Test fun nothingBeforeTheEnd() {
        val e = started()
        assertNull(e.tick(s(299)))
        assertEquals(1000L, e.remaining(s(299)))
    }

    @Test fun runToWalkChainsFromTheOldEnd() {
        val e = started()
        assertEquals(IntervalTransition(IntervalPhase.Run, IntervalPhase.Walk, 1), e.tick(s(300)))
        assertEquals(Status.Running(s(360)), e.state.status)
    }

    @Test fun walkToRunBumpsTheRound() {
        val e = started()
        e.tick(s(300))
        assertEquals(IntervalTransition(IntervalPhase.Walk, IntervalPhase.Run, 2), e.tick(s(360)))
        assertEquals(Status.Running(s(660)), e.state.status)
    }

    @Test fun asleepThroughSeveralEndsStepsThroughAll() {
        val e = started()
        assertEquals(IntervalTransition(IntervalPhase.Walk, IntervalPhase.Run, 3), e.tick(s(1000)))
        assertEquals(IntervalPhase.Run, e.phase)
        assertEquals(3, e.state.round)
        assertEquals(Status.Running(s(1020)), e.state.status)
        assertEquals(1_000_000L, e.elapsed(s(1000)))
    }

    @Test fun pauseKeepsRemainingAndExcludesPausedTime() {
        val e = started()
        e.pause(s(100))
        e.start(s(160))
        assertEquals(Status.Running(s(360)), e.state.status)
        assertEquals(140_000L, e.elapsed(s(200)))
    }

    @Test fun stopLogsOnlyAMinuteOrMore() {
        val e = started()
        assertNull(e.stop(s(30)))
        assertTrue(e.isIdle)

        val f = started()
        val r = f.stop(s(1000))!!
        assertEquals(1000.0, r.seconds, 0.0)
        assertEquals(t0, r.startedAt)
        assertEquals(s(1000), r.endedAt)
        assertTrue(f.isIdle)
    }

    @Test fun skipMovesOnNow() {
        val e = started()
        assertEquals(IntervalTransition(IntervalPhase.Run, IntervalPhase.Walk, 1), e.skip(s(30)))
        assertEquals(Status.Running(s(90)), e.state.status)
        assertNull(IntervalEngine().skip(t0))
    }

    @Test fun elapsedCapsAtADay() {
        val e = started()
        assertEquals(24 * 3600 * 1000L, e.elapsed(s(30 * 3600)))
    }
}
