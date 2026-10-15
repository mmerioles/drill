import Foundation

/// Hosted tokens expire after an hour and carry a refresh token;
/// self-hosted tokens never expire.
public struct Account: Codable, Equatable, Sendable {
    public var email: String
    public var token: String
    public var confirmed: Bool
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(email: String, token: String, confirmed: Bool,
                refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.email = email
        self.token = token
        self.confirmed = confirmed
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Where an account lives: drill's hosted sync (`SupabaseAPI`) or a
/// self-hosted server (`SyncAPI`). Both throw `SyncError`.
public protocol SyncBackend: Sendable {
    func signIn(email: String, password: String) async throws -> Account
    func createAccount(email: String, password: String) async throws -> SignUp
    /// Whether the email link for an account from `createAccount` was clicked.
    func isConfirmed(userID: String) async throws -> Bool
    /// Sends the confirmation email again.
    func resendLink(email: String) async throws
    /// The same account unless its token is about to expire, or `force`
    /// says the server turned it down.
    func refreshed(_ account: Account, force: Bool) async throws -> Account
    /// Best effort: signing out locally never waits on it.
    func signOut(_ account: Account) async
    func push(_ sessions: [FocusSession], deviceID: String, token: String) async throws
    func pull(after cursor: String, token: String) async throws -> SyncPage
}

public enum SignUp: Equatable, Sendable {
    case signedIn(Account)
    /// Sign in once `isConfirmed(userID:)` says so.
    case confirmByLink(userID: String)
}

public struct SyncPage: Decodable, Sendable {
    public var sessions: [FocusSession]
    public var cursor: String
    public var more: Bool
}

public enum SyncError: Error, Equatable, Sendable {
    case unreachable
    /// The token was revoked: sign in again.
    case signedOut
    case unconfirmed
    /// A sentence fit to show, like "wrong email or password".
    case rejected(String)
}

/// A self-hosted sync server (docs/SYNC.md). Stateless: callers keep the
/// account, cursor and push mark.
public struct SyncAPI: SyncBackend {
    public var server: URL
    private let session: URLSession

    public init(server: URL, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    /// "teto.example.com" and "https://teto.example.com/" both become
    /// https://teto.example.com. Typed http is kept, for local servers.
    public static func serverURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    // MARK: Accounts

    public func signIn(email: String, password: String) async throws -> Account {
        let body = try JSONEncoder().encode(["email": email, "password": password])
        return try await call("v1/signin", body: body, as: Account.self)
    }

    /// Self-hosted accounts sync before they're confirmed.
    public func createAccount(email: String, password: String) async throws -> SignUp {
        let body = try JSONEncoder().encode(["email": email, "password": password])
        return .signedIn(try await call("v1/accounts", body: body, as: Account.self))
    }

    public func isConfirmed(userID: String) async throws -> Bool { true }

    public func resendLink(email: String) async throws {
        throw SyncError.rejected("this server sends its own confirmation emails")
    }

    public func refreshed(_ account: Account, force: Bool) async throws -> Account {
        if force { throw SyncError.signedOut }
        return account
    }

    public func signOut(_ account: Account) async {
        _ = try? await call("v1/signout", token: account.token, body: Data("{}".utf8), as: Empty.self)
    }

    // MARK: Sessions

    public func push(_ sessions: [FocusSession], deviceID: String, token: String) async throws {
        struct Push: Encodable { var deviceID: String; var sessions: [FocusSession] }
        let body = try JSONEncoder.iso8601.encode(Push(deviceID: deviceID, sessions: sessions))
        _ = try await call("v1/sessions/push", token: token, body: body, as: Empty.self)
    }

    public func pull(after cursor: String, token: String) async throws -> SyncPage {
        let path = "v1/sessions/pull?cursor=" + (cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "0")
        return try await call(path, token: token, as: SyncPage.self)
    }

    // MARK: Plumbing

    private struct Empty: Decodable {}
    private struct Failure: Decodable { var error: String }

    private func call<T: Decodable>(_ path: String, token: String? = nil, body: Data? = nil,
                                    as: T.Type) async throws -> T {
        guard let url = URL(string: path, relativeTo: server.appending(path: "/")) else {
            throw SyncError.unreachable
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            do { return try JSONDecoder.iso8601.decode(T.self, from: data) } catch { throw SyncError.unreachable }
        case 401 where token != nil:
            throw SyncError.signedOut
        case 403:
            throw SyncError.unconfirmed
        default:
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw message.map(SyncError.rejected) ?? SyncError.unreachable
        }
    }
}

extension JSONEncoder {
    /// Dates as ISO 8601, as both sync backends expect.
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
