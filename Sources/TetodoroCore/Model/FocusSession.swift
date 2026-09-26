import Foundation

/// One block of focused time — the only record Tetodoro keeps.
///
/// Rows are never hard-deleted and never edited without bumping `updatedAt`,
/// so any two devices can merge their copies by last-writer-wins on `id`.
/// See docs/SYNC.md.
public struct FocusSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    /// Time actually spent focusing; excludes pauses.
    public var focusSeconds: TimeInterval
    public var plannedSeconds: TimeInterval
    /// False when the block was cut short by skip or reset.
    public var completed: Bool
    public var tag: String?
    public var deviceID: String
    public var updatedAt: Date
    /// Tombstone. Non-nil rows are hidden locally but still synced.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        focusSeconds: TimeInterval,
        plannedSeconds: TimeInterval,
        completed: Bool,
        tag: String? = nil,
        deviceID: String,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusSeconds = focusSeconds
        self.plannedSeconds = plannedSeconds
        self.completed = completed
        self.tag = tag
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
