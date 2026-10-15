import Foundation

public enum IntervalPhase: String, Codable, Sendable, CaseIterable {
    case run, walk

    public var next: IntervalPhase { self == .run ? .walk : .run }
}

public struct IntervalConfig: Codable, Equatable, Sendable {
    public var run: TimeInterval
    public var walk: TimeInterval

    public init(run: TimeInterval = 5 * 60, walk: TimeInterval = 60) {
        self.run = run
        self.walk = walk
    }

    public static let standard = IntervalConfig()

    public func duration(of phase: IntervalPhase) -> TimeInterval {
        phase == .run ? run : walk
    }
}

/// A whole run/walk workout, produced when it's stopped.
public struct WorkoutRecord: Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    /// Workout time, excluding pauses.
    public var seconds: TimeInterval
}

public struct IntervalTransition: Equatable, Sendable {
    public var finished: IntervalPhase
    public var next: IntervalPhase
    /// The round the workout is in after the transition.
    public var round: Int
}

/// Run/walk intervals. Like `PomodoroEngine`, time is passed in. Interval
/// ends chain from the previous deadline, so sleeping through several of
/// them steps through all of them without drift.
public struct IntervalEngine: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case idle
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    public var config: IntervalConfig
    public private(set) var phase: IntervalPhase = .run
    public private(set) var status: Status = .idle
    /// Run intervals started so far; 1 after start, 0 when idle.
    public private(set) var round = 0
    /// Workouts shorter than this are not worth logging.
    public var minimumLoggable: TimeInterval = 60
    /// Sync caps a session at a day.
    public static let longest: TimeInterval = 24 * 60 * 60

    private var workoutStartedAt: Date?
    /// Time counted before the current run, across pauses.
    private var accrued: TimeInterval = 0
    private var runStartedAt: Date?

    public init(config: IntervalConfig = .standard) {
        self.config = config
    }

    public var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    public var isIdle: Bool { status == .idle }

    public var duration: TimeInterval { config.duration(of: phase) }

    /// The interval that follows this one, and the round it will be in.
    public var upcoming: (phase: IntervalPhase, round: Int) {
        (phase.next, phase == .walk ? round + 1 : round)
    }

    public func remaining(at now: Date) -> TimeInterval {
        switch status {
        case .idle: duration
        case .paused(let remaining): remaining
        case .running(let endsAt): max(0, endsAt.timeIntervalSince(now))
        }
    }

    public func elapsed(at now: Date) -> TimeInterval {
        let live = runStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return min(Self.longest, accrued + live)
    }

    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }

    /// Seconds until the shown countdown (rounded up) next changes, landing
    /// just past the boundary. Nil unless running.
    public func untilNextSecond(at now: Date) -> TimeInterval? {
        guard isRunning else { return nil }
        let left = remaining(at: now)
        guard left > 0 else { return 0 }
        return left - (left - 1e-6).rounded(.down) + 0.004
    }

    // MARK: Controls

    public mutating func start(at now: Date) {
        guard status == .idle else { return }
        phase = .run
        round = 1
        workoutStartedAt = now
        accrued = 0
        run(for: config.run, from: now)
    }

    public mutating func pause(at now: Date) {
        guard case .running(let endsAt) = status else { return }
        accrued += now.timeIntervalSince(runStartedAt ?? now)
        runStartedAt = nil
        status = .paused(remaining: max(0, endsAt.timeIntervalSince(now)))
    }

    public mutating func resume(at now: Date) {
        guard case .paused(let remaining) = status else { return }
        run(for: remaining, from: now)
    }

    public mutating func toggle(at now: Date) {
        switch status {
        case .idle: start(at: now)
        case .running: pause(at: now)
        case .paused: resume(at: now)
        }
    }

    /// Advances the clock, stepping through every interval end that has
    /// passed. Returns the last transition, if any.
    public mutating func tick(at now: Date) -> IntervalTransition? {
        var last: IntervalTransition?
        while case .running(let endsAt) = status, now >= endsAt {
            last = advance(from: endsAt)
        }
        return last
    }

    /// Ends the current interval now and starts the next.
    public mutating func skip(at now: Date) -> IntervalTransition? {
        switch status {
        case .idle: return nil
        case .running: return advance(from: now)
        case .paused:
            let t = step()
            status = .paused(remaining: duration)
            return t
        }
    }

    /// Ends the workout, returning it for logging if long enough.
    public mutating func stop(at now: Date) -> WorkoutRecord? {
        defer {
            status = .idle
            phase = .run
            round = 0
            accrued = 0
            runStartedAt = nil
            workoutStartedAt = nil
        }
        guard let start = workoutStartedAt else { return nil }
        let seconds = elapsed(at: now)
        guard seconds >= minimumLoggable else { return nil }
        return WorkoutRecord(startedAt: start, endedAt: now, seconds: seconds)
    }

    // MARK: Internals

    private mutating func run(for seconds: TimeInterval, from now: Date) {
        runStartedAt = now
        status = .running(endsAt: now.addingTimeInterval(seconds))
    }

    private mutating func step() -> IntervalTransition {
        let finished = phase
        let (next, nextRound) = upcoming
        phase = next
        round = nextRound
        return IntervalTransition(finished: finished, next: next, round: round)
    }

    private mutating func advance(from endsAt: Date) -> IntervalTransition {
        let t = step()
        status = .running(endsAt: endsAt.addingTimeInterval(duration))
        return t
    }
}
