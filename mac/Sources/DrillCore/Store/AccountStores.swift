import Foundation

/// Sessions belong to one account. Signed out, the app uses the offline
/// store; signed in, that account's own store beside it. Only making an
/// account carries offline sessions over.
public struct AccountStores {
    public let offlineURL: URL

    public init(offlineURL: URL = SQLiteSessionStore.defaultURL) {
        self.offlineURL = offlineURL
    }

    public func url(for userID: String) -> URL {
        SQLiteSessionStore.accountURL(userID: userID, beside: offlineURL)
    }

    public func open(_ userID: String?) throws -> SQLiteSessionStore {
        try SQLiteSessionStore(url: userID.map(url(for:)) ?? offlineURL)
    }

    /// The account's sessions and its sync marks, after signing out.
    public func remove(_ userID: String, defaults: UserDefaults) {
        SQLiteSessionStore.remove(at: url(for: userID))
        SyncMarks(defaults: defaults, userID: userID).clear()
    }

    /// Making an account: every offline row (tombstones too) goes to the new
    /// account's store, unpushed there, and the offline store is emptied.
    public static func moveRows(from offline: SessionStore, to account: SessionStore) throws {
        for session in try offline.changes(since: .distantPast) { try account.save(session) }
        try offline.removeAll()
    }

    /// Once, before any store opens: before this version a signed-in Mac kept
    /// its account's sessions in the offline store. That file becomes the
    /// account's, with its push mark and cursor, so nothing uploads again.
    public func upgrade(signedInAs userID: String?, defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.upgraded) else { return }
        if let userID {
            let to = url(for: userID)
            let fm = FileManager.default
            if fm.fileExists(atPath: offlineURL.path), !fm.fileExists(atPath: to.path) {
                try? SQLiteSessionStore.move(offlineURL, to: to)
            }
            SyncMarks(defaults: defaults, userID: userID).adoptLegacy()
        }
        defaults.set(true, forKey: Self.upgraded)
    }

    static let upgraded = "drill.stores.split"
}

/// One account's place in the sync: when it last pushed, and the pull cursor.
public struct SyncMarks {
    let defaults: UserDefaults
    let userID: String

    public init(defaults: UserDefaults, userID: String) {
        self.defaults = defaults
        self.userID = userID
    }

    public var pushedAt: Date {
        get { defaults.object(forKey: key("pushedAt")) as? Date ?? .distantPast }
        nonmutating set { defaults.set(newValue, forKey: key("pushedAt")) }
    }

    public var cursor: String {
        get { defaults.string(forKey: key("cursor")) ?? "0" }
        nonmutating set { defaults.set(newValue, forKey: key("cursor")) }
    }

    public func clear() {
        defaults.removeObject(forKey: key("pushedAt"))
        defaults.removeObject(forKey: key("cursor"))
    }

    private func key(_ name: String) -> String { "drill.sync.\(name).\(userID)" }

    /// The marks every account shared before.
    static let legacy = ["pushedAt", "cursor"].map { "drill.sync.\($0)" }

    func adoptLegacy() {
        for (old, name) in zip(Self.legacy, ["pushedAt", "cursor"]) {
            if let value = defaults.object(forKey: old) { defaults.set(value, forKey: key(name)) }
            defaults.removeObject(forKey: old)
        }
    }
}
