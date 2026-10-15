import AppKit
import Observation
import DrillCore

/// The account and the sync loop (docs/SYNC.md, "Client loop"): push, then
/// pull. With auto sync on, runs at launch, after each write, every few
/// minutes and on return to the app; always on sign-in and on demand.
/// Each account syncs its own store (`AccountStores`) with its own marks.
///
/// The token lives in UserDefaults, not the Keychain: the app is ad-hoc
/// signed, so each update would prompt for a password to read the Keychain.
@Observable @MainActor
final class Sync {
    enum State: Equatable {
        case signedOut, idle, syncing, offline
    }

    private(set) var state: State
    private(set) var account: Account?
    /// Local rows not yet pushed.
    private(set) var unpushed = 0
    var autoSync: Bool {
        didSet {
            defaults.set(autoSync, forKey: Keys.auto)
            if autoSync { startLoop() } else { stopLoop() }
        }
    }

    /// "continue offline" was picked. Cleared on sign-out, so the welcome shows.
    var welcomed: Bool {
        didSet { defaults.set(welcomed, forKey: Keys.welcomed) }
    }

    /// The account's own store while signed in, else the offline one.
    private(set) var store: SessionStore
    /// Gets the new store when signing in or out swaps it.
    var onSwitch: (SessionStore) -> Void = { _ in }
    var onPulled: () -> Void = {}

    private let api = SupabaseAPI.hosted
    /// Nil for --render: one store, never swapped.
    private let stores: AccountStores?
    private let deviceID: String
    private let defaults: UserDefaults
    /// Last run's account that wasn't kept: pushed and wiped from `start`.
    private var leftover: Account?
    private var running: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var lastStarted: Date?
    private var started = false
    private var signingOut = false

    private static let every: Duration = .seconds(5 * 60)

    /// Opens the store of whoever is signed in. An account that wasn't kept
    /// is signed out here, before anything shows.
    convenience init(stores: AccountStores, defaults: UserDefaults = .standard) {
        var account = Self.decode(defaults.data(forKey: Keys.account))
        stores.upgrade(signedInAs: account?.userID, defaults: defaults)
        if account != nil, defaults.bool(forKey: Keys.ephemeral) {
            defaults.set(defaults.data(forKey: Keys.account), forKey: Keys.leftover)
            defaults.removeObject(forKey: Keys.account)
            defaults.removeObject(forKey: Keys.ephemeral)
            defaults.set(false, forKey: Keys.welcomed)
            account = nil
        }
        self.init(store: Self.open(stores, account?.userID), stores: stores, account: account, defaults: defaults,
                  welcomed: defaults.bool(forKey: Keys.welcomed))
        leftover = Self.decode(defaults.data(forKey: Keys.leftover))
    }

    /// For --render: signed out, on one store.
    convenience init(store: SessionStore, defaults: UserDefaults, welcomed: Bool = true) {
        self.init(store: store, stores: nil, account: nil, defaults: defaults, welcomed: welcomed)
    }

    private init(store: SessionStore, stores: AccountStores?, account: Account?, defaults: UserDefaults,
                 welcomed: Bool) {
        self.store = store
        self.stores = stores
        self.defaults = defaults
        self.deviceID = DeviceIdentity.current(defaults)
        self.account = account
        self.welcomed = welcomed
        autoSync = defaults.object(forKey: Keys.auto) as? Bool ?? true
        state = account == nil ? .signedOut : .idle
        countUnpushed()
    }

    private static func decode(_ data: Data?) -> Account? {
        data.flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
    }

    /// Keeps the timer usable even if the disk isn't; nothing is kept then.
    private static func open(_ stores: AccountStores, _ userID: String?) -> SessionStore {
        (try? stores.open(userID)) ?? (try! SQLiteSessionStore.inMemory())
    }

    var isSignedIn: Bool { account != nil }
    /// Signed in without "stay signed in": signed out on quit.
    var isEphemeral: Bool { isSignedIn && defaults.bool(forKey: Keys.ephemeral) }
    /// The welcome takes the main window until you sign in or go offline.
    var showsWelcome: Bool { !isSignedIn && !welcomed }

    /// The home link: only while there's something to send and nothing sending.
    var showsLink: Bool { isSignedIn && unpushed > 0 && state != .syncing }

    /// After a local write.
    func logged() {
        countUnpushed()
        if autoSync { syncNow() }
    }

    private func marks(_ account: Account) -> SyncMarks {
        SyncMarks(defaults: defaults, userID: account.userID)
    }

    private func countUnpushed() {
        guard let account else { unpushed = 0; return }
        unpushed = (try? store.changeCount(since: marks(account).pushedAt)) ?? 0
    }

    func start() {
        guard !started else { return }
        started = true
        startLoop()
        if let leftover { wipe(leftover) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
    }

    /// The periodic loop runs only while signed in with auto sync on.
    private func startLoop() {
        guard started, loop == nil, isSignedIn, autoSync else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncNow()
                try? await Task.sleep(for: Self.every, tolerance: .seconds(30))
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    private func cameBack() {
        guard autoSync else { return }
        if lastStarted.map({ $0.timeIntervalSinceNow < -20 }) ?? true { syncNow() }
    }

    // MARK: Account

    // These throw `Problem`, a sentence fit to show.

    /// Opens the account's own store: nothing from this Mac goes up with it.
    func signIn(username: String, password: String, staySignedIn: Bool) async throws {
        let account = try await attempt { try await api.signIn(username: username, password: password) }
        begin(account, staySignedIn: staySignedIn, carryingOffline: false)
    }

    /// The one time offline sessions join an account.
    func createAccount(username: String, password: String, staySignedIn: Bool) async throws {
        let account = try await attempt { try await api.createAccount(username: username, password: password) }
        begin(account, staySignedIn: staySignedIn, carryingOffline: true)
    }

    /// The live check on the create-account form. Throws on no answer.
    func usernameAvailable(_ name: String) async throws -> Bool {
        try await attempt { try await api.usernameAvailable(name) }
    }

    private func begin(_ account: Account, staySignedIn: Bool, carryingOffline: Bool) {
        let marks = marks(account)
        if let stores {
            let mine = Self.open(stores, account.userID)
            if carryingOffline {
                marks.clear()
                try? AccountStores.moveRows(from: store, to: mine)
            }
            use(mine)
        }
        marks.cursor = "0"
        defaults.set(!staySignedIn, forKey: Keys.ephemeral)
        save(account)
        state = .idle
        countUnpushed()
        syncNow()
    }

    private func use(_ new: SessionStore) {
        store = new
        onSwitch(new)
    }

    private func attempt<T: Sendable>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch SyncError.rejected(let message) {
            throw Problem(message)
        } catch {
            throw Problem("can't connect. try again in a bit.")
        }
    }

    /// Sends what's unsent (for up to 10 s), then forgets the account's
    /// sessions on this Mac. False, having done nothing, when they couldn't
    /// be sent and not `anyway`: ask first.
    @discardableResult
    func signOut(anyway: Bool = false) async -> Bool {
        guard let account, !signingOut else { return true }
        signingOut = true
        defer { signingOut = false }
        stopLoop()
        running?.cancel()
        await running?.value
        state = .syncing
        let sent = await pushBriefly(account, from: store)
        guard self.account?.userID == account.userID else { return true }
        countUnpushed()
        if !sent && !anyway && unpushed > 0 {
            state = .offline
            startLoop()
            return false
        }
        forget(account)
        return true
    }

    /// Quitting while signed in without "stay signed in".
    func quitting() async {
        guard isEphemeral, let account else { return }
        stopLoop()
        running?.cancel()
        await running?.value
        _ = await pushBriefly(account, from: store)
        if self.account?.userID == account.userID { forget(account) }
    }

    private func forget(_ account: Account) {
        let api = api, current = self.account ?? account
        Task { await api.signOut(current) }
        save(nil)
        defaults.removeObject(forKey: Keys.ephemeral)
        state = .signedOut
        welcomed = false
        if let stores {
            use(Self.open(stores, nil))
            stores.remove(account.userID, defaults: defaults)
        }
        countUnpushed()
    }

    /// Last run's unkept account: its sessions go up if they can, then go.
    private func wipe(_ old: Account) {
        guard let stores else { return }
        Task {
            if let oldStore = try? stores.open(old.userID) {
                _ = await pushBriefly(old, from: oldStore)
            }
            await api.signOut(old)
            if account?.userID != old.userID { stores.remove(old.userID, defaults: defaults) }
            defaults.removeObject(forKey: Keys.leftover)
            leftover = nil
        }
    }

    /// A push that gives up after 10 s. True once everything is sent.
    private func pushBriefly(_ account: Account, from store: SessionStore) async -> Bool {
        let work = Task { try await authorized(account) { token in try await self.push(store, as: account, token: token) } }
        let timer = Task {
            try? await Task.sleep(for: .seconds(10))
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            try await work.value
            return true
        } catch {
            return false
        }
    }

    struct Problem: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: Syncing

    func syncNow() {
        guard running == nil, !signingOut, let account else { return }
        lastStarted = Date()
        running = Task { [weak self] in
            await self?.run(as: account)
            self?.running = nil
            self?.countUnpushed()
        }
    }

    private func run(as start: Account) async {
        state = .syncing
        let store = store
        do {
            try await authorized(start) { token in try await self.exchange(store, as: start, token: token) }
            guard account?.userID == start.userID else { return } // signed out meanwhile
            state = .idle
        } catch SyncError.signedOut {
            guard account?.userID == start.userID else { return }
            dropped()
        } catch {
            if account?.userID == start.userID { state = .offline }
        }
    }

    /// The server ended the session. The account's store stays, unsent rows
    /// and all, for signing in again.
    private func dropped() {
        save(nil)
        defaults.removeObject(forKey: Keys.ephemeral)
        state = .signedOut
        welcomed = false
        if let stores { use(Self.open(stores, nil)) }
        countUnpushed()
    }

    /// Runs `work` with a fresh token, and once more with a newer one if
    /// it's turned down anyway.
    private func authorized(_ start: Account, _ work: (String) async throws -> Void) async throws {
        do {
            try await work(try await fresh(start, force: false))
        } catch SyncError.signedOut where start.refreshToken != nil {
            try await work(try await fresh(start, force: true))
        }
    }

    private func fresh(_ start: Account, force: Bool) async throws -> String {
        let current = account?.userID == start.userID ? account ?? start : start
        let fresh = try await api.refreshed(current, force: force)
        if fresh != current, account?.userID == start.userID { save(fresh) }
        return fresh.token
    }

    private func push(_ store: SessionStore, as account: Account, token: String) async throws {
        let marks = marks(account)
        let mark = Date()
        let changes = try store.changes(since: marks.pushedAt)
        for start in stride(from: 0, to: changes.count, by: 200) {
            try await api.push(Array(changes[start..<min(start + 200, changes.count)]),
                               deviceID: deviceID, token: token)
        }
        marks.pushedAt = mark
    }

    private func exchange(_ store: SessionStore, as account: Account, token: String) async throws {
        try await push(store, as: account, token: token)
        let marks = marks(account)
        var pulled = false
        var page: SyncPage
        repeat {
            page = try await api.pull(after: marks.cursor, token: token)
            for session in page.sessions { try store.save(session) }
            pulled = pulled || !page.sessions.isEmpty
            marks.cursor = page.cursor
        } while page.more
        if pulled, store === self.store { onPulled() }
    }

    private func save(_ account: Account?) {
        self.account = account
        if let account, let data = try? JSONEncoder().encode(account) {
            defaults.set(data, forKey: Keys.account)
            startLoop()
        } else {
            defaults.removeObject(forKey: Keys.account)
            stopLoop()
        }
    }

    private enum Keys {
        static let account = "drill.sync.account"
        static let ephemeral = "drill.sync.ephemeral"
        static let leftover = "drill.sync.leftover"
        static let welcomed = "drill.welcomed"
        static let auto = "drill.sync.auto"
    }
}
