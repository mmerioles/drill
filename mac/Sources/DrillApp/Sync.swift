import AppKit
import Observation
import DrillCore

/// The account and the sync loop (docs/SYNC.md, "Client loop"): push, then
/// pull. With auto sync on, runs at launch, after each write, every few
/// minutes and on return to the app; always on sign-in and on demand.
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

    private let api = SupabaseAPI.hosted
    private let store: SessionStore
    private let deviceID: String
    private let defaults: UserDefaults
    private let onPulled: () -> Void
    private var running: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var lastStarted: Date?
    private var started = false

    private static let every: Duration = .seconds(5 * 60)

    init(store: SessionStore, deviceID: String, defaults: UserDefaults = .standard,
         onPulled: @escaping () -> Void) {
        self.store = store
        self.deviceID = deviceID
        self.defaults = defaults
        self.onPulled = onPulled
        let account = defaults.data(forKey: Keys.account).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        self.account = account
        autoSync = defaults.object(forKey: Keys.auto) as? Bool ?? true
        state = account == nil ? .signedOut : .idle
        countUnpushed()
    }

    var isSignedIn: Bool { account != nil }

    /// The home link: only while there's something to send and nothing sending.
    var showsLink: Bool { isSignedIn && unpushed > 0 && state != .syncing }

    /// After a local write.
    func logged() {
        countUnpushed()
        if autoSync { syncNow() }
    }

    private func countUnpushed() {
        let since = defaults.object(forKey: Keys.pushedAt) as? Date ?? .distantPast
        unpushed = (try? store.changeCount(since: since)) ?? 0
    }

    func start() {
        guard !started else { return }
        started = true
        startLoop()
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

    func signIn(username: String, password: String) async throws {
        begin(try await attempt { try await api.signIn(username: username, password: password) })
    }

    func createAccount(username: String, password: String) async throws {
        begin(try await attempt { try await api.createAccount(username: username, password: password) })
    }

    /// The live check on the create-account form. Throws on no answer.
    func usernameAvailable(_ name: String) async throws -> Bool {
        try await attempt { try await api.usernameAvailable(name) }
    }

    /// Uploads everything on this Mac and pulls from the start.
    private func begin(_ account: Account) {
        save(account)
        defaults.removeObject(forKey: Keys.pushedAt)
        defaults.removeObject(forKey: Keys.cursor)
        state = .idle
        countUnpushed()
        syncNow()
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

    func signOut() {
        if let account {
            let api = api
            Task { await api.signOut(account) }
        }
        running?.cancel()
        save(nil)
        state = .signedOut
    }

    struct Problem: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: Syncing

    func syncNow() {
        guard running == nil, let account else { return }
        lastStarted = Date()
        running = Task { [weak self] in
            await self?.run(as: account)
            self?.running = nil
            self?.countUnpushed()
        }
    }

    private func run(as start: Account) async {
        state = .syncing
        var token = start.token
        do {
            // Refresh a nearly-expired token, and once more if it's rejected anyway.
            token = try await fresh(start, force: false)
            do {
                try await exchange(token: token)
            } catch SyncError.signedOut where start.refreshToken != nil {
                token = try await fresh(start, force: true)
                try await exchange(token: token)
            }
            guard account?.token == token else { return } // signed out meanwhile
            state = .idle
        } catch SyncError.signedOut {
            guard account?.username == start.username else { return }
            save(nil)
            state = .signedOut
        } catch {
            if account?.username == start.username { state = .offline }
        }
    }

    private func fresh(_ start: Account, force: Bool) async throws -> String {
        let current = account ?? start
        let fresh = try await api.refreshed(current, force: force)
        if fresh != current, account?.username == start.username { save(fresh) }
        return fresh.token
    }

    private func exchange(token: String) async throws {
        let mark = Date()
        let since = defaults.object(forKey: Keys.pushedAt) as? Date ?? .distantPast
        let changes = try store.changes(since: since)
        for start in stride(from: 0, to: changes.count, by: 200) {
            try await api.push(Array(changes[start..<min(start + 200, changes.count)]),
                               deviceID: deviceID, token: token)
        }
        defaults.set(mark, forKey: Keys.pushedAt)

        var pulled = false
        var page: SyncPage
        repeat {
            page = try await api.pull(after: defaults.string(forKey: Keys.cursor) ?? "0", token: token)
            for session in page.sessions { try store.save(session) }
            pulled = pulled || !page.sessions.isEmpty
            defaults.set(page.cursor, forKey: Keys.cursor)
        } while page.more
        if pulled { onPulled() }
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
        static let cursor = "drill.sync.cursor"
        static let pushedAt = "drill.sync.pushedAt"
        static let auto = "drill.sync.auto"
    }
}
