import Foundation
import Testing
@testable import DrillCore

@Suite struct StopwatchTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func countsUpFromWallClock() {
        var w = Stopwatch()
        #expect(w.elapsed(at: t0) == 0)
        w.start(at: t0)
        #expect(w.elapsed(at: t0 + 90) == 90)
    }

    @Test func pausesLeaveTimeOut() throws {
        var w = Stopwatch()
        w.start(at: t0)
        w.pause(at: t0 + 100)
        #expect(w.elapsed(at: t0 + 500) == 100)
        w.start(at: t0 + 500)
        #expect(w.elapsed(at: t0 + 560) == 160)
        let reset = w.reset(at: t0 + 560)
        let r = try #require(reset)
        #expect(r.focusSeconds == 160)
        #expect(r.startedAt == t0)
        #expect(r.endedAt == t0 + 560)
        #expect(r.plannedSeconds == 0)
        #expect(r.completed)
        #expect(w.isIdle)
        #expect(w.elapsed(at: t0 + 600) == 0)
    }

    @Test func shortBlocksAreNotLogged() {
        var w = Stopwatch()
        w.start(at: t0)
        #expect(w.reset(at: t0 + 30) == nil)
        #expect(w.isIdle)
        #expect(w.reset(at: t0 + 40) == nil) // idle: nothing to log
    }

    @Test func stopsCountingAfterADay() {
        var w = Stopwatch()
        w.start(at: t0)
        #expect(w.elapsed(at: t0 + 2 * Stopwatch.longest) == Stopwatch.longest)
        #expect(w.untilNextSecond(at: t0 + 2 * Stopwatch.longest) == nil)
    }

    @Test func wakesWhenTheShownSecondChanges() throws {
        var w = Stopwatch()
        #expect(w.untilNextSecond(at: t0) == nil)
        w.start(at: t0)
        let wait = try #require(w.untilNextSecond(at: t0 + 2.25))
        #expect(abs(wait - 0.754) < 1e-6)
        w.pause(at: t0 + 3)
        #expect(w.untilNextSecond(at: t0 + 4) == nil)
    }
}
