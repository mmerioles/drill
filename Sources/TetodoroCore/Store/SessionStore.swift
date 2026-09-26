import Foundation

/// Where sessions live. The app talks only to this protocol, so SQLite can be
/// swapped (or wrapped by a syncing store) without touching UI code.
public protocol SessionStore: AnyObject {
    /// Inserts or updates by `id`. An incoming row only replaces an existing
    /// one if its `updatedAt` is newer — the same rule sync merges by.
    func save(_ session: FocusSession) throws

    /// Live (non-deleted) sessions that started within `[from, to)`, oldest first.
    func sessions(from: Date, to: Date) throws -> [FocusSession]

    /// Distinct tags, most recently used first.
    func tags(limit: Int) throws -> [String]

    /// Every row touched after `since`, tombstones included. The sync push set.
    func changes(since: Date) throws -> [FocusSession]
}
