import Foundation

/// The seam where home-server sync plugs in. The MVP ships `DisabledSync`;
/// an HTTP client implementing docs/SYNC.md replaces it without touching
/// the engine, the store, or any view.
public protocol SyncService: Sendable {
    /// Pushes local rows changed since the last successful sync, pulls remote
    /// rows, and merges them into the store (last-writer-wins on `updatedAt`).
    func sync(_ store: SessionStore) async throws
}

public struct DisabledSync: SyncService {
    public init() {}
    public func sync(_ store: SessionStore) async throws {}
}

/// A stable per-install identifier stamped on every session, so the server
/// (and you) can tell which machine a study session came from.
public enum DeviceIdentity {
    private static let key = "tetodoro.deviceID"

    public static func current(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: key) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}
