import Foundation
import TetodoroCore

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

    static func finished(_ phase: Phase) -> (title: String, body: String) {
        phase == .focus ? ("focus done", "time for a break") : ("break over", "back to focus")
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
