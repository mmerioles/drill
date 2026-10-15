import Foundation

public protocol SessionStore: AnyObject {
    /// Upserts by `id`, only replacing a row with an older `updatedAt`.
    func save(_ session: FocusSession) throws

    /// Live (non-deleted) sessions that started within `[from, to)`, oldest first.
    func sessions(from: Date, to: Date) throws -> [FocusSession]

    /// Distinct tags, most recently used first.
    func tags(limit: Int) throws -> [String]

    /// Every row touched after `since`, tombstones included. The sync push set.
    func changes(since: Date) throws -> [FocusSession]
}
