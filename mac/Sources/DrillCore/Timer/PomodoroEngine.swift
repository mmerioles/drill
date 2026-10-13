import Foundation

/// Focus time that should be written down, produced when a focus block ends.
public struct FocusRecord: Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var focusSeconds: TimeInterval
    public var plannedSeconds: TimeInterval
    public var completed: Bool
}

public struct Transition: Equatable, Sendable {
    public var finished: Phase
    public var next: Phase
    /// Present when the finished phase was focus and enough time was spent.
    public var record: FocusRecord?
    /// True when the phase ran to zero rather than being skipped.
    public var natural: Bool
}

/// The pomodoro state machine. A plain value with time passed in, so it never
/// drifts, survives sleep, and is trivially testable.
///
/// The engine owns no clock: the host calls `tick(at:)` as often as it likes
/// and gets back a `Transition` when a phase ends.
public struct PomodoroEngine: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case idle
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    public var config: TimerConfig
    public private(set) var phase: Phase = .focus
    public private(set) var status: Status = .idle
    /// Focus blocks finished or skipped since launch; drives the long-break cadence.
    public private(set) var focusCount = 0
    /// Cut-short focus blocks shorter than this are not worth logging.
    public var minimumLoggable: TimeInterval = 60

    private var blockStartedAt: Date?
    private var accrued: TimeInterval = 0
    private var runStartedAt: Date?

    public init(config: TimerConfig = .standard) {
        self.config = config
    }

    public var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    public var isIdle: Bool { status == .idle }

    public var duration: TimeInterval { config.duration(of: phase) }

    /// Position within the current long-break cycle, 0..<longBreakEvery.
    public var cyclePosition: Int { focusCount % config.longBreakEvery }

    public func remaining(at now: Date) -> TimeInterval {
        switch status {
        case .idle: duration
        case .paused(let remaining): remaining
        case .running(let endsAt): max(0, endsAt.timeIntervalSince(now))
        }
    }

    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }

    // MARK: Controls

    public mutating func start(at now: Date) {
        switch status {
        case .running:
            return
        case .idle:
            blockStartedAt = now
            accrued = 0
            run(for: duration, from: now)
        case .paused(let remaining):
            run(for: remaining, from: now)
        }
    }

    public mutating func pause(at now: Date) {
        guard case .running(let endsAt) = status else { return }
        accrued += now.timeIntervalSince(runStartedAt ?? now)
        runStartedAt = nil
        status = .paused(remaining: max(0, endsAt.timeIntervalSince(now)))
    }

    public mutating func toggle(at now: Date) {
        isRunning ? pause(at: now) : start(at: now)
    }

    /// Advances the clock. Returns a transition if the running phase hit zero.
    public mutating func tick(at now: Date) -> Transition? {
        guard case .running(let endsAt) = status, now >= endsAt else { return nil }
        return finish(endedAt: endsAt, natural: true, now: now)
    }

    /// Ends the current phase early and moves to the next one, left idle.
    public mutating func skip(at now: Date) -> Transition {
        finish(endedAt: now, natural: false, now: now)
    }

    /// Abandons the current phase and rewinds it to full. Focus time already
    /// spent is still returned for logging — studying is studying.
    public mutating func reset(at now: Date) -> FocusRecord? {
        let record = phase == .focus ? focusRecord(endedAt: now, completed: false) : nil
        clearBlock()
        return record
    }

    // MARK: Internals

    private mutating func run(for seconds: TimeInterval, from now: Date) {
        runStartedAt = now
        status = .running(endsAt: now.addingTimeInterval(seconds))
    }

    private func elapsed(at time: Date) -> TimeInterval {
        let live = runStartedAt.map { max(0, time.timeIntervalSince($0)) } ?? 0
        return min(duration, accrued + live)
    }

    private func focusRecord(endedAt: Date, completed: Bool) -> FocusRecord? {
        guard let start = blockStartedAt else { return nil }
        let focused = elapsed(at: endedAt)
        guard completed || focused >= minimumLoggable else { return nil }
        return FocusRecord(
            startedAt: start, endedAt: endedAt, focusSeconds: focused,
            plannedSeconds: config.focus, completed: completed)
    }

    private mutating func clearBlock() {
        blockStartedAt = nil
        runStartedAt = nil
        accrued = 0
        status = .idle
    }

    private mutating func finish(endedAt: Date, natural: Bool, now: Date) -> Transition {
        let finished = phase
        var record: FocusRecord?

        if finished == .focus {
            record = focusRecord(endedAt: endedAt, completed: natural)
            // A skipped focus block still counts as a round, so skipping
            // keeps building towards the long break like any pomodoro timer.
            focusCount += 1
            let longDue = focusCount % config.longBreakEvery == 0
            phase = longDue ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }
        clearBlock()

        // Auto-started phases begin at `now`, not at the old deadline, so a
        // Mac that slept through several phases wakes to one transition
        // instead of a chain of phantom sessions.
        let autoStart = phase.isBreak ? config.autoStartBreaks : config.autoStartFocus
        if natural && autoStart { start(at: now) }

        return Transition(finished: finished, next: phase, record: record, natural: natural)
    }
}
