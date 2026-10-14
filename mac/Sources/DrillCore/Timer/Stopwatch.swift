import Foundation

/// A plain stopwatch for blocks of time that aren't pomodoros: it counts up
/// until you stop it. Like `PomodoroEngine`, a value with time passed in, so
/// it never drifts and survives sleep.
public struct Stopwatch: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case idle
        case running(since: Date)
        case paused
    }

    public private(set) var status: Status = .idle
    /// Blocks shorter than this are not worth logging.
    public var minimumLoggable: TimeInterval = 60
    /// The longest block it counts: sync keeps a session to a day.
    public static let longest: TimeInterval = 24 * 60 * 60

    private var blockStartedAt: Date?
    /// Time counted before the current run, across pauses.
    private var accrued: TimeInterval = 0

    public init() {}

    public var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    public var isIdle: Bool { status == .idle }

    /// Time counted so far, pauses left out.
    public func elapsed(at now: Date) -> TimeInterval {
        var total = accrued
        if case .running(let since) = status { total += max(0, now.timeIntervalSince(since)) }
        return min(Self.longest, total)
    }

    /// Seconds from `now` until the shown count (whole seconds, rounded
    /// down) next changes, landing just past the boundary. Nil unless running.
    public func untilNextSecond(at now: Date) -> TimeInterval? {
        guard isRunning else { return nil }
        let e = elapsed(at: now)
        guard e < Self.longest else { return nil }
        return (e + 1e-6).rounded(.down) + 1 - e + 0.004
    }

    // MARK: Controls

    public mutating func start(at now: Date) {
        switch status {
        case .running: return
        case .idle:
            blockStartedAt = now
            accrued = 0
        case .paused: break
        }
        status = .running(since: now)
    }

    public mutating func pause(at now: Date) {
        guard isRunning else { return }
        accrued = elapsed(at: now)
        status = .paused
    }

    public mutating func toggle(at now: Date) {
        isRunning ? pause(at: now) : start(at: now)
    }

    /// Ends the block and returns it for logging when it's long enough: a
    /// stopwatch block is done when you say so, so it counts as completed.
    /// It has no plan, so planned time is zero.
    public mutating func reset(at now: Date) -> FocusRecord? {
        defer {
            status = .idle
            accrued = 0
            blockStartedAt = nil
        }
        guard let start = blockStartedAt else { return nil }
        let counted = elapsed(at: now)
        guard counted >= minimumLoggable else { return nil }
        return FocusRecord(startedAt: start, endedAt: now, focusSeconds: counted,
                           plannedSeconds: 0, completed: true)
    }
}
