import Foundation

public enum Phase: String, Codable, Sendable, CaseIterable {
    case focus, shortBreak, longBreak

    public var isBreak: Bool { self != .focus }
}

public struct TimerConfig: Codable, Equatable, Sendable {
    public var focus: TimeInterval
    public var shortBreak: TimeInterval
    public var longBreak: TimeInterval
    /// A long break replaces every Nth short break.
    public var longBreakEvery: Int
    public var autoStartBreaks: Bool
    public var autoStartFocus: Bool

    public init(
        focus: TimeInterval = 25 * 60,
        shortBreak: TimeInterval = 5 * 60,
        longBreak: TimeInterval = 15 * 60,
        longBreakEvery: Int = 4,
        autoStartBreaks: Bool = true,
        autoStartFocus: Bool = false
    ) {
        self.focus = focus
        self.shortBreak = shortBreak
        self.longBreak = longBreak
        self.longBreakEvery = max(1, longBreakEvery)
        self.autoStartBreaks = autoStartBreaks
        self.autoStartFocus = autoStartFocus
    }

    public static let standard = TimerConfig()

    public func duration(of phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: focus
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }
}
