import Foundation

public struct HeatmapDay: Equatable, Sendable {
    public var date: Date
    public var seconds: TimeInterval
    public var level: Int
}

/// A GitHub-style year of days, laid out in week columns.
public struct Heatmap: Equatable, Sendable {
    /// `weeks[column][row]`; row 0 is the calendar's first weekday.
    /// Nil marks days after today in the final column.
    public var weeks: [[HeatmapDay?]]
    public var today: TimeInterval
    public var thisWeek: TimeInterval
    /// Consecutive days with any focus, ending today (or yesterday, so a
    /// streak is not "broken" before today's session has happened).
    public var streak: Int

    public static let empty = Heatmap(weeks: [], today: 0, thisWeek: 0, streak: 0)
}

public struct HeatmapBuilder: Sendable {
    public var calendar: Calendar
    public var weeks: Int

    public init(calendar: Calendar = .current, weeks: Int = 53) {
        self.calendar = calendar
        self.weeks = weeks
    }

    /// Intensity 0–4. Fixed thresholds rather than relative to your best day,
    /// so a cell means the same thing next year as it does today.
    public static func level(for seconds: TimeInterval) -> Int {
        switch seconds {
        case ..<60: 0
        case ..<(30 * 60): 1
        case ..<(90 * 60): 2
        case ..<(180 * 60): 3
        default: 4
        }
    }

    /// The date range the grid covers — query the store with this.
    public func range(today: Date) -> (from: Date, to: Date) {
        let weekStart = startOfWeek(today)
        let from = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: weekStart)!
        let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!
        return (from, to)
    }

    public func dailyTotals(_ sessions: [FocusSession]) -> [Date: TimeInterval] {
        sessions.reduce(into: [:]) { totals, s in
            totals[calendar.startOfDay(for: s.startedAt), default: 0] += s.focusSeconds
        }
    }

    public func build(_ sessions: [FocusSession], today: Date = Date()) -> Heatmap {
        let totals = dailyTotals(sessions)
        let todayStart = calendar.startOfDay(for: today)
        let gridStart = range(today: today).from

        let columns: [[HeatmapDay?]] = (0..<weeks).map { w in
            (0..<7).map { d in
                let date = calendar.date(byAdding: .day, value: w * 7 + d, to: gridStart)!
                guard date <= todayStart else { return nil }
                let seconds = totals[date] ?? 0
                return HeatmapDay(date: date, seconds: seconds, level: Self.level(for: seconds))
            }
        }

        let weekStart = startOfWeek(today)
        let thisWeek = totals.filter { $0.key >= weekStart }.values.reduce(0, +)

        var streak = 0
        var cursor = todayStart
        if (totals[cursor] ?? 0) == 0 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        while (totals[cursor] ?? 0) > 0 {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        return Heatmap(
            weeks: columns, today: totals[todayStart] ?? 0, thisWeek: thisWeek, streak: streak)
    }

    private func startOfWeek(_ date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
