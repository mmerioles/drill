import Foundation
import Observation
import TetodoroCore

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

    /// Where accounts live unless settings name a self-hosted server. Nil
    /// until ours is up; until then syncing needs a self-hosted server.
    static let defaultServer: URL? = nil

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

    var server: URL? { customServer.flatMap(URL.init(string:)) ?? Self.defaultServer }

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

    /// Signs in, or makes the account first. Everything already on this Mac
    /// joins the account. Throws a sentence fit to show.
    func signIn(email: String, password: String, create: Bool) async throws {
        guard let server else { throw Problem("sync isn't open yet. to self-host, add your server in settings.") }
        let account: Account
        do {
            account = try await SyncAPI(server: server).signIn(email: email, password: password, create: create)
        } catch SyncError.rejected(let message) {
            throw Problem(message)
        } catch {
            throw Problem("can't reach the server. try again in a bit.")
        }
        save(account)
        // Upload everything, and catch up from the start.
        defaults.removeObject(forKey: Keys.pushedAt)
        defaults.removeObject(forKey: Keys.cursor)
        state = .idle
        syncNow()
    }

    func signOut() {
        if let token = account?.token, let server {
            let api = SyncAPI(server: server)
            Task { await api.signOut(token) }
        }
        running?.cancel()
        save(nil)
        state = .signedOut
    }

    struct Problem: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: Syncing

    /// Starts a sync unless one is already running.
    func syncNow() {
        guard running == nil, let account, let server else { return }
        let api = SyncAPI(server: server)
        running = Task { [weak self] in
            await self?.run(api, token: account.token)
            self?.running = nil
        }
    }

    private func run(_ api: SyncAPI, token: String) async {
        state = .syncing
        do {
            let mark = Date()
            let since = defaults.object(forKey: Keys.pushedAt) as? Date ?? .distantPast
            let changes = try store.changes(since: since)
            for start in stride(from: 0, to: changes.count, by: 200) {
                try await api.push(Array(changes[start..<min(start + 200, changes.count)]),
                                   deviceID: deviceID, token: token)
            }
            defaults.set(mark, forKey: Keys.pushedAt)

            var pulled = false
            var page: SyncAPI.Page
            repeat {
                page = try await api.pull(after: defaults.string(forKey: Keys.cursor) ?? "0", token: token)
                for session in page.sessions { try store.save(session) }
                pulled = pulled || !page.sessions.isEmpty
                defaults.set(page.cursor, forKey: Keys.cursor)
            } while page.more
            if pulled { onPulled() }

            guard account?.token == token else { return } // signed out meanwhile
            state = .idle
            flashSynced()
        } catch SyncError.signedOut {
            save(nil)
            state = .signedOut
        } catch SyncError.unconfirmed {
            state = .unconfirmed
        } catch {
            if account?.token == token { state = .offline }
        }
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
        static let account = "tetodoro.sync.account"
        static let server = "tetodoro.sync.server" // self-hosted only
        static let cursor = "tetodoro.sync.cursor"
        static let pushedAt = "tetodoro.sync.pushedAt"
    }
}
