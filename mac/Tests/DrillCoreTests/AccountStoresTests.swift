import Foundation
import Testing
@testable import DrillCore

@Suite struct AccountStoresTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drill-stores-\(UUID().uuidString)")
    var stores: AccountStores { AccountStores(offlineURL: folder.appendingPathComponent("drill.sqlite")) }
    let defaults: UserDefaults = {
        let name = "drill.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }()

    /// The offline store from before accounts were required.
    func legacy() throws -> SQLiteSessionStore { try SQLiteSessionStore(url: stores.offlineURL) }

    func session(_ at: TimeInterval) -> FocusSession {
        let start = Date(timeIntervalSince1970: at)
        return FocusSession(startedAt: start, endedAt: start + 1500, focusSeconds: 1500, plannedSeconds: 1500,
                            completed: true, tag: "jp", deviceID: "test", updatedAt: start)
    }

    @Test func accountsKeepTheirOwnSessions() throws {
        let a = try stores.open("aaa")
        try a.save(session(100))
        SyncMarks(defaults: defaults, userID: "aaa").pushedAt = Date(timeIntervalSince1970: 50)

        let b = try stores.open("bbb")
        #expect(try b.changes(since: SyncMarks(defaults: defaults, userID: "bbb").pushedAt).isEmpty)
        #expect(try b.sessions(from: .distantPast, to: .distantFuture).isEmpty)
        #expect(try legacy().changes(since: .distantPast).isEmpty)
        #expect(try a.changeCount(since: SyncMarks(defaults: defaults, userID: "aaa").pushedAt) == 1)
        #expect(stores.url(for: "aaa").lastPathComponent == "drill-aaa.sqlite")
    }

    @Test func aNewAccountStartsEmpty() throws {
        try legacy().save(session(100))
        try stores.open("aaa").save(session(200))
        SyncMarks(defaults: defaults, userID: "aaa").pushedAt = Date(timeIntervalSince1970: 50)

        let mine = try stores.open("new")
        #expect(try mine.sessions(from: .distantPast, to: .distantFuture).isEmpty)
        #expect(try mine.changes(since: SyncMarks(defaults: defaults, userID: "new").pushedAt).isEmpty)
        #expect(try legacy().changes(since: .distantPast).count == 1)
        #expect(try stores.open("aaa").changes(since: .distantPast).count == 1)
    }

    @Test func signingOutForgetsTheAccount() throws {
        try stores.open("aaa").save(session(100))
        let marks = SyncMarks(defaults: defaults, userID: "aaa")
        marks.cursor = "9"
        stores.remove("aaa", defaults: defaults)
        #expect(!FileManager.default.fileExists(atPath: stores.url(for: "aaa").path))
        #expect(marks.cursor == "0")
        #expect(try stores.open("aaa").changes(since: .distantPast).isEmpty)
    }

    @Test func upgradeMovesTheOfflineStoreOnceAndKeepsItsMarks() throws {
        let pushed = Date(timeIntervalSince1970: 150)
        do {
            let old = try legacy()
            try old.save(session(100))
            try old.save(session(200))
        }
        defaults.set(pushed, forKey: "drill.sync.pushedAt")
        defaults.set("42", forKey: "drill.sync.cursor")

        stores.upgrade(signedInAs: "aaa", defaults: defaults)
        let marks = SyncMarks(defaults: defaults, userID: "aaa")
        #expect(marks.pushedAt == pushed)
        #expect(marks.cursor == "42")
        #expect(defaults.object(forKey: "drill.sync.pushedAt") == nil)
        #expect(try stores.open("aaa").changeCount(since: marks.pushedAt) == 1)
        #expect(try legacy().changes(since: .distantPast).isEmpty)

        // Never again, even for another account.
        try legacy().save(session(300))
        stores.upgrade(signedInAs: "bbb", defaults: defaults)
        #expect(!FileManager.default.fileExists(atPath: stores.url(for: "bbb").path))
        #expect(try legacy().changes(since: .distantPast).count == 1)
    }

    @Test func upgradeSignedOutMovesNothing() throws {
        try legacy().save(session(100))
        stores.upgrade(signedInAs: nil, defaults: defaults)
        #expect(try legacy().changes(since: .distantPast).count == 1)
        #expect(defaults.bool(forKey: AccountStores.upgraded))
    }

    @Test func userIDComesFromTheToken() {
        func jwt(_ claims: String) -> String {
            let body = Data(claims.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJIUzI1NiJ9.\(body).sig"
        }
        let id = "6F1C2A3B-0000-4000-8000-0123456789AB"
        #expect(Account(email: "teto@example.com", token: jwt(#"{"sub":"\#(id)","role":"authenticated"}"#)).userID == id.lowercased())
        #expect(Account(email: "teto@example.com", token: "tok").userID == "teto@example.com")
    }
}
