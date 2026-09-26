import Foundation
import Testing
@testable import TetodoroCore

@Suite struct SQLiteSessionStoreTests {
    func session(_ start: Date, minutes: Double, tag: String? = nil, updated: Date? = nil) -> FocusSession {
        FocusSession(startedAt: start, endedAt: start + minutes * 60, focusSeconds: minutes * 60,
                     plannedSeconds: 25 * 60, completed: true, tag: tag, deviceID: "test",
                     updatedAt: updated ?? start)
    }

    @Test func roundTripsAndFiltersByRange() throws {
        let store = try SQLiteSessionStore.inMemory()
        let a = session(Date(timeIntervalSince1970: 100), minutes: 25, tag: "jp")
        let b = session(Date(timeIntervalSince1970: 5000), minutes: 10)
        try store.save(a)
        try store.save(b)
        #expect(try store.sessions(from: .distantPast, to: .distantFuture) == [a, b])
        #expect(try store.sessions(from: Date(timeIntervalSince1970: 1000), to: .distantFuture) == [b])
    }

    @Test func olderWriteNeverOverwritesNewer() throws {
        let store = try SQLiteSessionStore.inMemory()
        var s = session(Date(timeIntervalSince1970: 100), minutes: 25, updated: Date(timeIntervalSince1970: 200))
        try store.save(s)
        var stale = s
        stale.tag = "stale"
        stale.updatedAt = Date(timeIntervalSince1970: 150)
        try store.save(stale)
        #expect(try store.sessions(from: .distantPast, to: .distantFuture).first?.tag == nil)

        s.tag = "fresh"
        s.updatedAt = Date(timeIntervalSince1970: 300)
        try store.save(s)
        #expect(try store.sessions(from: .distantPast, to: .distantFuture).first?.tag == "fresh")
    }

    @Test func tombstonesHideButStillSync() throws {
        let store = try SQLiteSessionStore.inMemory()
        var s = session(Date(timeIntervalSince1970: 100), minutes: 25)
        try store.save(s)
        s.deletedAt = Date(timeIntervalSince1970: 400)
        s.updatedAt = Date(timeIntervalSince1970: 400)
        try store.save(s)
        #expect(try store.sessions(from: .distantPast, to: .distantFuture).isEmpty)
        #expect(try store.changes(since: Date(timeIntervalSince1970: 300)).map(\.id) == [s.id])
    }

    @Test func tagsAreMostRecentFirst() throws {
        let store = try SQLiteSessionStore.inMemory()
        try store.save(session(Date(timeIntervalSince1970: 100), minutes: 5, tag: "math"))
        try store.save(session(Date(timeIntervalSince1970: 200), minutes: 5, tag: "jp"))
        try store.save(session(Date(timeIntervalSince1970: 300), minutes: 5))
        #expect(try store.tags(limit: 10) == ["jp", "math"])
    }
}

@Suite struct HeatmapBuilderTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = 1
        return c
    }

    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func session(_ start: Date, minutes: Double) -> FocusSession {
        FocusSession(startedAt: start, endedAt: start + minutes * 60, focusSeconds: minutes * 60,
                     plannedSeconds: 1500, completed: true, deviceID: "t")
    }

    @Test func levelsUseFixedThresholds() {
        #expect(HeatmapBuilder.level(for: 0) == 0)
        #expect(HeatmapBuilder.level(for: 25 * 60) == 1)
        #expect(HeatmapBuilder.level(for: 60 * 60) == 2)
        #expect(HeatmapBuilder.level(for: 2 * 3600) == 3)
        #expect(HeatmapBuilder.level(for: 4 * 3600) == 4)
    }

    @Test func gridEndsOnTodaysWeekAndHidesTheFuture() throws {
        let builder = HeatmapBuilder(calendar: calendar)
        let today = at(2026, 9, 26) // a Saturday — last row of its column
        let map = builder.build([session(at(2026, 9, 26, 9), minutes: 50)], today: today)
        #expect(map.weeks.count == 53)
        let lastDay = try #require(map.weeks.last?.last ?? nil)
        #expect(calendar.isDate(lastDay.date, inSameDayAs: today))
        #expect(lastDay.level == 2)

        let wednesday = at(2026, 9, 23)
        let midweek = builder.build([], today: wednesday)
        #expect(midweek.weeks.last?[3] != nil)
        #expect(midweek.weeks.last?[4] == nil)
    }

    @Test func streakSurvivesAnEmptyToday() {
        let builder = HeatmapBuilder(calendar: calendar)
        let sessions = [at(2026, 9, 23), at(2026, 9, 24), at(2026, 9, 25)].map { session($0, minutes: 25) }
        #expect(builder.build(sessions, today: at(2026, 9, 26)).streak == 3)
        #expect(builder.build(sessions, today: at(2026, 9, 27)).streak == 0)
    }

    @Test func totalsForTodayAndWeek() {
        let builder = HeatmapBuilder(calendar: calendar)
        let sessions = [
            session(at(2026, 9, 19), minutes: 60), // previous week
            session(at(2026, 9, 21), minutes: 30),
            session(at(2026, 9, 26, 8), minutes: 25),
            session(at(2026, 9, 26, 15), minutes: 25),
        ]
        let map = builder.build(sessions, today: at(2026, 9, 26, 20))
        #expect(map.today == 50 * 60)
        #expect(map.thisWeek == 80 * 60)
    }
}
