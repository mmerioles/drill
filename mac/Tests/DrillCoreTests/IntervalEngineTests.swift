import Foundation
import Testing
@testable import DrillCore

@Suite struct IntervalEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let config = IntervalConfig(run: 300, walk: 60)

    private func started() -> IntervalEngine {
        var e = IntervalEngine(config: config)
        e.start(at: t0)
        return e
    }

    @Test func startsOnRunRoundOne() {
        var e = IntervalEngine(config: config)
        #expect(e.isIdle)
        #expect(e.round == 0)
        #expect(e.remaining(at: t0) == 300)
        e.start(at: t0)
        #expect(e.phase == .run)
        #expect(e.round == 1)
        #expect(e.status == .running(endsAt: t0 + 300))
        #expect(e.elapsed(at: t0 + 10) == 10)
    }

    @Test func ticksBeforeTheEndDoNothing() {
        var e = started()
        #expect(e.tick(at: t0 + 299) == nil)
        #expect(e.remaining(at: t0 + 299) == 1)
        #expect(e.phase == .run)
    }

    @Test func runEndsIntoWalkAndWalkIntoTheNextRound() {
        var e = started()
        #expect(e.tick(at: t0 + 300) == IntervalTransition(finished: .run, next: .walk, round: 1))
        #expect(e.status == .running(endsAt: t0 + 360))
        #expect(e.tick(at: t0 + 360) == IntervalTransition(finished: .walk, next: .run, round: 2))
        #expect(e.status == .running(endsAt: t0 + 660))
    }

    @Test func catchesUpThroughEveryMissedBoundary() {
        var e = started()
        let t = e.tick(at: t0 + 1000)
        #expect(t == IntervalTransition(finished: .walk, next: .run, round: 3))
        #expect(e.phase == .run)
        #expect(e.round == 3)
        #expect(e.status == .running(endsAt: t0 + 1020))
        #expect(e.elapsed(at: t0 + 1000) == 1000)
    }

    @Test func pauseKeepsRemainingAndLeavesPausedTimeOut() {
        var e = started()
        e.pause(at: t0 + 100)
        #expect(e.status == .paused(remaining: 200))
        #expect(e.elapsed(at: t0 + 150) == 100)
        e.resume(at: t0 + 160)
        #expect(e.status == .running(endsAt: t0 + 360))
        #expect(e.elapsed(at: t0 + 200) == 140)
    }

    @Test func stopLogsOnlyAMinuteOrMore() throws {
        var short = started()
        #expect(short.stop(at: t0 + 30) == nil)
        #expect(short.isIdle)
        #expect(short.round == 0)
        #expect(short.stop(at: t0 + 40) == nil) // idle: nothing to log

        var long = started()
        let stopped = long.stop(at: t0 + 1000)
        let r = try #require(stopped)
        #expect(r.seconds == 1000)
        #expect(r.startedAt == t0)
        #expect(r.endedAt == t0 + 1000)
        #expect(long.isIdle)
        #expect(long.phase == .run)
    }

    @Test func skipMovesOnNow() {
        var e = started()
        #expect(e.skip(at: t0 + 50) == IntervalTransition(finished: .run, next: .walk, round: 1))
        #expect(e.status == .running(endsAt: t0 + 110))
        #expect(e.skip(at: t0 + 70) == IntervalTransition(finished: .walk, next: .run, round: 2))
        #expect(e.status == .running(endsAt: t0 + 370))

        var idle = IntervalEngine(config: config)
        #expect(idle.skip(at: t0) == nil)

        var paused = started()
        paused.pause(at: t0 + 10)
        #expect(paused.skip(at: t0 + 20)?.next == .walk)
        #expect(paused.status == .paused(remaining: 60))
    }

    @Test func toggleWalksIdleRunningPaused() {
        var e = IntervalEngine(config: config)
        e.toggle(at: t0)
        #expect(e.isRunning)
        e.toggle(at: t0 + 10)
        #expect(e.status == .paused(remaining: 290))
        e.toggle(at: t0 + 20)
        #expect(e.status == .running(endsAt: t0 + 310))
    }

    @Test func elapsedStopsAfterADay() {
        let e = started()
        #expect(e.elapsed(at: t0 + 2 * IntervalEngine.longest) == IntervalEngine.longest)
    }

    @Test func upcomingNamesTheNextIntervalAndRound() {
        var e = started()
        #expect(e.upcoming.phase == .walk)
        #expect(e.upcoming.round == 1)
        _ = e.tick(at: t0 + 300)
        #expect(e.upcoming.phase == .run)
        #expect(e.upcoming.round == 2)
    }

    @Test func wakesOncePerShownSecond() throws {
        var e = IntervalEngine(config: config)
        #expect(e.untilNextSecond(at: t0) == nil)
        e.start(at: t0)
        let wait = try #require(e.untilNextSecond(at: t0 + 10.7))
        #expect(abs(wait - 0.304) < 1e-6)
        #expect(e.untilNextSecond(at: t0 + 400) == 0)
    }
}
