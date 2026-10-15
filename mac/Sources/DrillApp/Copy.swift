import Foundation
import DrillCore

/// Every user-facing sentence in one place. Lowercase, short, kind.
enum Copy {
    /// Nil when idle on focus: an idle timer needs no caption.
    static func status(_ phase: Phase, running: Bool, active: Bool) -> String? {
        switch (phase, active, running) {
        case (.focus, false, _): nil
        case (_, true, false): "paused"
        default: phaseName(phase)
        }
    }

    static func toggle(running: Bool, active: Bool) -> String {
        running ? "pause" : active ? "resume" : "start"
    }

    /// The banner when a phase runs out. `next` is the next phase's length.
    static func finished(_ phase: Phase, next: TimeInterval) -> (title: String, body: String) {
        let minutes = max(1, Int((next / 60).rounded()))
        return phase == .focus ? ("focus done", "take a break · \(minutes) min") : ("break over", "back to focus")
    }

    static func startNext(_ next: Phase) -> String {
        next.isBreak ? "start break" : "start focus"
    }

    /// VoiceOver: "12 minutes left".
    static func spokenLeft(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total >= 60 {
            let m = Int((Double(total) / 60).rounded(.up))
            return m == 1 ? "1 minute left" : "\(m) minutes left"
        }
        return total == 1 ? "1 second left" : "\(total) seconds left"
    }

    /// VoiceOver: "12 minutes".
    static func spokenCounted(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 60 {
            let m = total / 60
            return m == 1 ? "1 minute" : "\(m) minutes"
        }
        return total == 1 ? "1 second" : "\(total) seconds"
    }

    static func modeName(stopwatch: Bool) -> String { stopwatch ? "stopwatch" : "pomodoro" }

    static func phaseName(_ phase: Phase) -> String {
        switch phase {
        case .focus: "focus"
        case .shortBreak: "break"
        case .longBreak: "long break"
        }
    }

    /// A countdown rounds up (it never shows 00:00 with time left); a count
    /// up rounds down (it never shows a second that hasn't passed).
    static func clock(_ seconds: TimeInterval, countingUp: Bool = false) -> String {
        let total = Int(countingUp ? (seconds + 1e-6).rounded(.down) : seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    static func amount(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m)m"
        case (_, 0): return "\(h)h"
        default: return "\(h)h \(m)m"
        }
    }

    /// "off", "30m", "2h", "1h 30m".
    static func goal(_ seconds: TimeInterval) -> String {
        seconds <= 0 ? "off" : amount(seconds)
    }

    /// "9:05 am".
    static let timeFormat: Date.FormatStyle = .dateTime.hour().minute()

    static func streak(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    static let dayFormat: Date.FormatStyle = .dateTime.weekday(.abbreviated).month(.abbreviated).day()
}
