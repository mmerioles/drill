import Foundation
import Observation
import DrillCore

/// Your account and the sync loop (docs/SYNC.md, "Client loop"): push what
/// changed here, then pull what changed elsewhere. Runs at launch, after each
/// logged block, every few minutes, and when you press sync.
///
/// The token is kept in UserDefaults, not the Keychain: the app is ad-hoc
/// signed, so every update would make macOS ask for your password to let
/// the new build read its own Keychain item.
@Observable @MainActor
final class Sync {
    enum State: Equatable {
        case signedOut, idle, syncing, offline, unconfirmed
    }

    private(set) var state: State
    private(set) var account: Account?
    /// True for a moment after a sync lands, for a quiet "synced".
    private(set) var justSynced = false
    /// A self-hosted server from settings, or nil for ours.
    private(set) var customServer: String?

    private let store: SessionStore
    private let deviceID: String
    private let defaults: UserDefaults
    private let onPulled: () -> Void
    private var running: Task<Void, Never>?
    private var loop: Task<Void, Never>?

    private static let every: Duration = .seconds(5 * 60)

    init(store: SessionStore, deviceID: String, defaults: UserDefaults = .standard,
         onPulled: @escaping () -> Void) {
        self.store = store
        self.deviceID = deviceID
        self.defaults = defaults
        self.onPulled = onPulled
        let account = defaults.data(forKey: Keys.account).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        self.account = account
        customServer = defaults.string(forKey: Keys.server)
        state = account == nil ? .signedOut : .idle
    }

    var isSignedIn: Bool { account != nil }

    /// The self-hosted server from settings, or ours on Supabase.
    var backend: any SyncBackend {
        customServer.flatMap(URL.init(string:)).map { SyncAPI(server: $0) } ?? SupabaseAPI.hosted
    }

    /// Points sync at a self-hosted server, or back at ours with an empty
    /// string. Only while signed out: a token only works where it was made.
    /// Throws a sentence fit to show.
    func setServer(_ text: String) throws {
        guard !isSignedIn else { throw Problem("sign out to change servers.") }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            customServer = nil
            defaults.removeObject(forKey: Keys.server)
            return
        }
        guard let url = SyncAPI.serverURL(text) else { throw Problem("that server address doesn't look right.") }
        customServer = url.absoluteString
        defaults.set(customServer, forKey: Keys.server)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncNow()
                try? await Task.sleep(for: Self.every)
            }
        }
    }

    // MARK: Account

    /// An account made here whose email link hasn't been clicked yet. Lives
    /// in memory only, password and all, just long enough to sign in by
    /// itself once the link is clicked.
    struct Waiting: Equatable {
        let email: String
        fileprivate let password: String
        /// Nil when signing in found the email unconfirmed: then the only
        /// way to tell is to try signing in again, less often.
        fileprivate let userID: String?
        /// True for a moment once the link is clicked, for the check mark.
        var confirmed = false
    }

    private(set) var waiting: Waiting?
    private var watching: Task<Void, Never>?

    // Each throws a sentence fit to show.

    func signIn(email: String, password: String) async throws {
        stopWaiting()
        do {
            try await begin(attempt { try await backend.signIn(email: email, password: password) })
        } catch is Unconfirmed {
            watch(Waiting(email: email, password: password, userID: nil))
        }
    }

    /// Makes the account, then signs in, or waits for the email link.
    func createAccount(email: String, password: String) async throws {
        stopWaiting()
        switch try await attempt({ try await backend.createAccount(email: email, password: password) }) {
        case .signedIn(let account): begin(account)
        case .confirmByLink(let id): watch(Waiting(email: email, password: password, userID: id))
        }
    }

    func resendLink() async throws {
        guard let waiting else { return }
        try await attempt { try await backend.resendLink(email: waiting.email) }
    }

    /// Gives up waiting, for a wrong email or a change of mind.
    func stopWaiting() {
        watching?.cancel()
        watching = nil
        waiting = nil
    }

    /// Checks every few seconds whether the link was clicked, then signs in.
    private func watch(_ start: Waiting) {
        watching?.cancel()
        waiting = start
        let backend = backend
        let began = Date()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                // Quick at first, while they're likely at their inbox.
                let quick = began.timeIntervalSinceNow > -30 * 60
                try? await Task.sleep(for: .seconds(start.userID == nil ? 10 : quick ? 3 : 30))
                guard !Task.isCancelled else { return }
                do {
                    if let id = start.userID, try await !backend.isConfirmed(userID: id) { continue }
                    let account = try await backend.signIn(email: start.email, password: start.password)
                    await self?.confirmed(account)
                    return
                } catch SyncError.rejected {
                    self?.stopWaiting() // the password changed elsewhere: sign in by hand
                    return
                } catch {
                    continue // not yet, or offline for a moment
                }
            }
        }
    }

    private func confirmed(_ account: Account) async {
        guard waiting != nil, !Task.isCancelled else { return }
        waiting?.confirmed = true
        begin(account)
        try? await Task.sleep(for: .seconds(2.5))
        if waiting?.confirmed == true { waiting = nil }
        watching = nil
    }

    /// Everything already on this Mac joins the account.
    private func begin(_ account: Account) {
        save(account)
        // Upload everything, and catch up from the start.
        defaults.removeObject(forKey: Keys.pushedAt)
        defaults.removeObject(forKey: Keys.cursor)
        state = .idle
        syncNow()
    }

    private func attempt<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch SyncError.rejected(let message) {
            throw Problem(message)
        } catch SyncError.unconfirmed {
            throw Unconfirmed()
        } catch {
            throw Problem("can't reach the server. try again in a bit.")
        }
    }

    func signOut() {
        stopWaiting()
        if let account {
            let backend = backend
            Task { await backend.signOut(account) }
        }
        running?.cancel()
        save(nil)
        state = .signedOut
    }

    /// Signing in to an account whose email isn't confirmed yet.
    private struct Unconfirmed: Error {}
    struct Problem: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: Syncing

    /// Starts a sync unless one is already running.
    func syncNow() {
        guard running == nil, let account else { return }
        let backend = backend
        running = Task { [weak self] in
            await self?.run(backend, as: account)
            self?.running = nil
        }
    }

    private func run(_ api: any SyncBackend, as start: Account) async {
        state = .syncing
        var token = start.token
        do {
            // Hosted tokens last an hour: swap one that's nearly out, and
            // once more if the server turns it down anyway.
            token = try await fresh(api, start, force: false)
            do {
                try await exchange(api, token: token)
            } catch SyncError.signedOut where start.refreshToken != nil {
                token = try await fresh(api, start, force: true)
                try await exchange(api, token: token)
            }
            guard account?.token == token else { return } // signed out meanwhile
            state = .idle
            flashSynced()
        } catch SyncError.signedOut {
            guard account?.email == start.email else { return }
            save(nil)
            state = .signedOut
        } catch SyncError.unconfirmed {
            state = .unconfirmed
        } catch {
            if account?.email == start.email { state = .offline }
        }
    }

    /// A token good for a while, saved for next time.
    private func fresh(_ api: any SyncBackend, _ start: Account, force: Bool) async throws -> String {
        let current = account ?? start
        let fresh = try await api.refreshed(current, force: force)
        if fresh != current, account?.email == start.email { save(fresh) }
        return fresh.token
    }

    /// Push what changed here, then pull what changed elsewhere.
    private func exchange(_ api: any SyncBackend, token: String) async throws {
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

    private func flashSynced() {
        justSynced = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.justSynced = false
        }
    }

    private func save(_ account: Account?) {
        self.account = account
        if let account, let data = try? JSONEncoder().encode(account) {
            defaults.set(data, forKey: Keys.account)
        } else {
            defaults.removeObject(forKey: Keys.account)
        }
    }

    private enum Keys {
        static let account = "drill.sync.account"
        static let server = "drill.sync.server" // self-hosted only
        static let cursor = "drill.sync.cursor"
        static let pushedAt = "drill.sync.pushedAt"
    }
}
