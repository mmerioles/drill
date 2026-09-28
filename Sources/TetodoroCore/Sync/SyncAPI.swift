import Foundation

/// Who you're signed in as. The token stands in for the password on every
/// call after sign-in.
public struct Account: Codable, Equatable, Sendable {
    public var email: String
    public var token: String
    public var confirmed: Bool

    public init(email: String, token: String, confirmed: Bool) {
        self.email = email
        self.token = token
        self.confirmed = confirmed
    }
}

public enum SyncError: Error, Equatable, Sendable {
    /// No answer from the server; try again later.
    case unreachable
    /// The token was revoked or never existed: sign in again.
    case signedOut
    /// The server wants the email confirmed before it syncs.
    case unconfirmed
    /// The server said no, with a sentence fit to show, like
    /// "wrong email or password".
    case rejected(String)
}

/// The sync server's API, as in docs/SYNC.md. Stateless: callers keep the
/// account, cursor and push mark.
public struct SyncAPI: Sendable {
    public var server: URL
    private let session: URLSession

    public init(server: URL, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    /// "teto.example.com" and "https://teto.example.com/" both become
    /// https://teto.example.com. Plain http is kept when typed, for a server
    /// on your own network.
    public static func serverURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    // MARK: Accounts

    /// Signs in, or makes the account first when `create` is set.
    public func signIn(email: String, password: String, create: Bool = false) async throws -> Account {
        let body = try JSONEncoder().encode(["email": email, "password": password])
        return try await call(create ? "v1/accounts" : "v1/signin", body: body, as: Account.self)
    }

    /// Revokes the token. Best effort: signing out locally never waits on it.
    public func signOut(_ token: String) async {
        _ = try? await call("v1/signout", token: token, body: Data("{}".utf8), as: Empty.self)
    }

    // MARK: Sessions

    public func push(_ sessions: [FocusSession], deviceID: String, token: String) async throws {
        struct Push: Encodable { var deviceID: String; var sessions: [FocusSession] }
        let body = try Self.encoder.encode(Push(deviceID: deviceID, sessions: sessions))
        _ = try await call("v1/sessions/push", token: token, body: body, as: Empty.self)
    }

    public struct Page: Decodable, Sendable {
        public var sessions: [FocusSession]
        public var cursor: String
        public var more: Bool
    }

    public func pull(after cursor: String, token: String) async throws -> Page {
        let path = "v1/sessions/pull?cursor=" + (cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "0")
        return try await call(path, token: token, as: Page.self)
    }

    // MARK: Plumbing

    private struct Empty: Decodable {}
    private struct Failure: Decodable { var error: String }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

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
            do { return try Self.decoder.decode(T.self, from: data) } catch { throw SyncError.unreachable }
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
