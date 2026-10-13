import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

/// SessionStore on the system SQLite. No dependencies; one file on disk.
public final class SQLiteSessionStore: SessionStore {
    private var db: OpaquePointer?

    /// Opens (creating if needed) the database at `url`.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path)
    }

    public static func inMemory() throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: ":memory:")
    }

    private init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw SQLiteError(description: "could not open \(path)")
        }
        try migrate()
    }

    deinit { sqlite3_close(db) }

    /// ~/Library/Application Support/Drill/drill.sqlite
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Drill", directoryHint: .isDirectory)
            .appending(path: "drill.sqlite")
    }

    // MARK: Schema

    private func migrate() throws {
        try exec("PRAGMA journal_mode = WAL")
        var version = 0
        try query("PRAGMA user_version") { version = Int($0.int(0)) }

        if version < 1 {
            try exec("""
                CREATE TABLE sessions (
                    id              TEXT PRIMARY KEY,
                    started_at      REAL NOT NULL,
                    ended_at        REAL NOT NULL,
                    focus_seconds   REAL NOT NULL,
                    planned_seconds REAL NOT NULL,
                    completed       INTEGER NOT NULL,
                    tag             TEXT,
                    device_id       TEXT NOT NULL,
                    updated_at      REAL NOT NULL,
                    deleted_at      REAL
                );
                CREATE INDEX sessions_started ON sessions(started_at);
                CREATE INDEX sessions_updated ON sessions(updated_at);
                PRAGMA user_version = 1;
                """)
        }
    }

    // MARK: SessionStore

    public func save(_ s: FocusSession) throws {
        try query("""
            INSERT INTO sessions (id, started_at, ended_at, focus_seconds, planned_seconds,
                                  completed, tag, device_id, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                started_at = excluded.started_at, ended_at = excluded.ended_at,
                focus_seconds = excluded.focus_seconds, planned_seconds = excluded.planned_seconds,
                completed = excluded.completed, tag = excluded.tag, device_id = excluded.device_id,
                updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
            WHERE excluded.updated_at > sessions.updated_at
            """,
            bind: [
                .text(s.id.uuidString), .date(s.startedAt), .date(s.endedAt),
                .real(s.focusSeconds), .real(s.plannedSeconds), .int(s.completed ? 1 : 0),
                s.tag.map(Value.text) ?? .null, .text(s.deviceID), .date(s.updatedAt),
                s.deletedAt.map(Value.date) ?? .null,
            ])
    }

    public func sessions(from: Date, to: Date) throws -> [FocusSession] {
        var out: [FocusSession] = []
        try query(
            "SELECT \(Self.columns) FROM sessions WHERE deleted_at IS NULL AND started_at >= ? AND started_at < ? ORDER BY started_at",
            bind: [.date(from), .date(to)]
        ) { out.append(Self.session(from: $0)) }
        return out
    }

    public func tags(limit: Int) throws -> [String] {
        var out: [String] = []
        try query(
            "SELECT tag FROM sessions WHERE tag IS NOT NULL AND deleted_at IS NULL GROUP BY tag ORDER BY MAX(started_at) DESC LIMIT ?",
            bind: [.int(Int64(limit))]
        ) { if let t = $0.text(0) { out.append(t) } }
        return out
    }

    public func changes(since: Date) throws -> [FocusSession] {
        var out: [FocusSession] = []
        try query(
            "SELECT \(Self.columns) FROM sessions WHERE updated_at > ? ORDER BY updated_at",
            bind: [.date(since)]
        ) { out.append(Self.session(from: $0)) }
        return out
    }

    private static let columns =
        "id, started_at, ended_at, focus_seconds, planned_seconds, completed, tag, device_id, updated_at, deleted_at"

    private static func session(from r: Row) -> FocusSession {
        FocusSession(
            id: UUID(uuidString: r.text(0) ?? "") ?? UUID(),
            startedAt: r.date(1), endedAt: r.date(2),
            focusSeconds: r.real(3), plannedSeconds: r.real(4),
            completed: r.int(5) != 0, tag: r.text(6), deviceID: r.text(7) ?? "",
            updatedAt: r.date(8), deletedAt: r.isNull(9) ? nil : r.date(9))
    }

    // MARK: Tiny SQLite layer

    private enum Value {
        case text(String), real(Double), int(Int64), date(Date), null
    }

    private struct Row {
        let stmt: OpaquePointer
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func real(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: real(i)) }
        func text(_ i: Int32) -> String? {
            sqlite3_column_text(stmt, i).map { String(cString: $0) }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func query(_ sql: String, bind: [Value] = [], row: ((Row) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }

        for (offset, value) in bind.enumerated() {
            let i = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, i, s, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(stmt, i, d)
            case .int(let n): sqlite3_bind_int64(stmt, i, n)
            case .date(let d): sqlite3_bind_double(stmt, i, d.timeIntervalSince1970)
            case .null: sqlite3_bind_null(stmt, i)
            }
        }

        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: row?(Row(stmt: stmt))
            case SQLITE_DONE: return
            default: throw lastError()
            }
        }
    }

    private func lastError() -> SQLiteError {
        SQLiteError(description: String(cString: sqlite3_errmsg(db)))
    }
}
