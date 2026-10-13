import Foundation
import DrillCore

/// Every user-facing sentence in one place. Lowercase, short, kind.
enum Copy {
    /// The word under the ring's top edge. Nil when idle on focus — an idle
    /// timer needs no caption.
    static func status(_ phase: Phase, running: Bool, active: Bool) -> String? {
        switch (phase, active, running) {
        case (.focus, false, _): nil
        case (_, true, false): "paused"
        case (.focus, _, _): "focus"
        case (.shortBreak, _, _): "break"
        case (.longBreak, _, _): "long break"
        }
    }

    /// The banner when a phase runs out. `next` is the phase that follows,
    /// and its length, for "take a break · 5 min".
    static func finished(_ phase: Phase, next: TimeInterval) -> (title: String, body: String) {
        let minutes = max(1, Int((next / 60).rounded()))
        return phase == .focus ? ("focus done", "take a break · \(minutes) min") : ("break over", "back to focus")
    }

    /// The banner's one action, when the next phase won't start by itself.
    static func startNext(_ next: Phase) -> String {
        next.isBreak ? "start break" : "start focus"
    }

    /// What VoiceOver says for the countdown: "12 minutes left".
    static func spokenLeft(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total >= 60 {
            let m = Int((Double(total) / 60).rounded(.up))
            return m == 1 ? "1 minute left" : "\(m) minutes left"
        }
        return total == 1 ? "1 second left" : "\(total) seconds left"
    }

    /// The ring's spoken name: the phase, whether or not it's running.
    static func phaseName(_ phase: Phase) -> String {
        switch phase {
        case .focus: "focus"
        case .shortBreak: "break"
        case .longBreak: "long break"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
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

    static func streak(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    static let dayFormat: Date.FormatStyle = .dateTime.weekday(.abbreviated).month(.abbreviated).day()
}
