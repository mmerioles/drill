import Foundation
import Testing
@testable import TetodoroCore

@Suite struct PomodoroEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let config = TimerConfig(focus: 100, shortBreak: 10, longBreak: 30, longBreakEvery: 2,
                             autoStartBreaks: true, autoStartFocus: false)

    @Test func countsDownFromWallClock() {
        var e = PomodoroEngine(config: config)
        e.start(at: t0)
        #expect(e.remaining(at: t0 + 40) == 60)
        #expect(e.tick(at: t0 + 99) == nil)
    }

    @Test func pauseFreezesRemainingAndExcludesPausedTime() throws {
        var e = PomodoroEngine(config: config)
        e.start(at: t0)
        e.pause(at: t0 + 30)
        #expect(e.remaining(at: t0 + 500) == 70)
        e.start(at: t0 + 500)
        let tick570 = e.tick(at: t0 + 570)
        let t = try #require(tick570)
        let r = try #require(t.record)
        #expect(r.focusSeconds == 100)
        #expect(r.startedAt == t0)
        #expect(r.endedAt == t0 + 570)
        #expect(r.completed)
    }

    @Test func completedFocusAutoStartsBreakFromNow() throws {
        var e = PomodoroEngine(config: config)
        e.start(at: t0)
        // Asleep well past the deadline: the break starts at wake, not at t0+100.
        let tick1000 = e.tick(at: t0 + 1000)
        let t = try #require(tick1000)
        #expect(t.next == .shortBreak)
        #expect(e.status == .running(endsAt: t0 + 1010))
        #expect(e.tick(at: t0 + 1000) == nil)
    }

    @Test func everyNthBreakIsLong() throws {
        var e = PomodoroEngine(config: config)
        e.start(at: t0)
        #expect(e.tick(at: t0 + 100)?.next == .shortBreak)
        #expect(e.tick(at: t0 + 110)?.next == .focus)
        #expect(e.isIdle) // autoStartFocus is off
        e.start(at: t0 + 200)
        #expect(e.tick(at: t0 + 300)?.next == .longBreak)
    }

    @Test func skippingFocusLogsPartialTimeOnlyAboveMinimum() {
        var e = PomodoroEngine(config: TimerConfig(focus: 25 * 60))
        e.start(at: t0)
        #expect(e.skip(at: t0 + 30).record == nil)

        var f = PomodoroEngine(config: TimerConfig(focus: 25 * 60))
        f.start(at: t0)
        let t = f.skip(at: t0 + 600)
        #expect(t.record?.focusSeconds == 600)
        #expect(t.record?.completed == false)
        #expect(t.next == .shortBreak)
        #expect(f.isIdle) // skipped phases never auto-start
        #expect(f.focusCount == 1)
    }

    @Test func skippingFocusBuildsTowardsTheLongBreak() {
        var e = PomodoroEngine(config: TimerConfig(longBreakEvery: 4))
        var phases: [Phase] = []
        for _ in 0..<8 { phases.append(e.skip(at: t0).next) }
        #expect(phases == [.shortBreak, .focus, .shortBreak, .focus,
                           .shortBreak, .focus, .longBreak, .focus])
        #expect(e.cyclePosition == 0)
    }

    @Test func resetKeepsStudiedTimeAndRewinds() {
        var e = PomodoroEngine(config: TimerConfig(focus: 25 * 60))
        e.start(at: t0)
        let r = e.reset(at: t0 + 300)
        #expect(r?.focusSeconds == 300)
        #expect(e.isIdle)
        #expect(e.remaining(at: t0 + 300) == 25 * 60)
        #expect(e.phase == .focus)
    }
}
