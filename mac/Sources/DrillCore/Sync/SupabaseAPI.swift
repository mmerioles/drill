import Foundation

/// Drill's sync: Supabase Auth for accounts, and the RPCs in
/// supabase/migrations for sessions. The publishable key is meant to ship in
/// apps; row-level security keeps each account to its own rows.
public struct SupabaseAPI: Sendable {
    public var project: URL
    public var key: String
    private let session: URLSession

    public init(project: URL, key: String, session: URLSession = .shared) {
        self.project = project
        self.key = key
        self.session = session
    }

    public static let hosted = SupabaseAPI(
        project: URL(string: "https://fgqtpetuzseozttapzem.supabase.co")!,
        key: "sb_publishable_WeTl_T2-z_i1ycA7KSgCyQ_9a64WoAg")

    /// Auth wants an email, so every username gets one here. Never shown,
    /// and the domain can't receive mail.
    public static let emailDomain = "users.mmerioles.github.io"

    public static func email(for username: String) -> String {
        "\(username)@\(emailDomain)"
    }

    /// The email with its domain stripped: works offline, no extra fetch.
    public static func username(from email: String) -> String {
        String(email.prefix { $0 != "@" })
    }

    /// Tokens this close to running out are swapped before a sync.
    private static let margin: TimeInterval = 5 * 60

    // MARK: Accounts

    public func signIn(username: String, password: String) async throws -> Account {
        try await tokens("auth/v1/token?grant_type=password",
                         ["email": Self.email(for: username), "password": password])
    }

    /// The username rides along as metadata; a trigger makes the profile,
    /// and a taken name fails the whole sign-up.
    public func createAccount(username: String, password: String) async throws -> Account {
        struct Body: Encodable { var email: String; var password: String; var data: [String: String] }
        let body = try JSONEncoder().encode(
            Body(email: Self.email(for: username), password: password, data: ["username": username]))
        return try account(from: try await call("auth/v1/signup", body: body, signingUp: true))
    }

    /// The live check while typing. False for names failing the rule too.
    public func usernameAvailable(_ name: String) async throws -> Bool {
        let body = try JSONEncoder().encode(["name": name])
        let data = try await call("rest/v1/rpc/username_available", body: body)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// The same account unless its token is about to expire, or `force`
    /// says the server turned it down.
    public func refreshed(_ account: Account, force: Bool) async throws -> Account {
        guard let refresh = account.refreshToken else { throw SyncError.signedOut }
        if !force, let expiresAt = account.expiresAt, expiresAt.timeIntervalSinceNow > Self.margin {
            return account
        }
        do {
            return try await tokens("auth/v1/token?grant_type=refresh_token", ["refresh_token": refresh])
        } catch SyncError.rejected {
            throw SyncError.signedOut // the refresh token was used up or revoked
        }
    }

    /// Best effort: signing out locally never waits on it.
    public func signOut(_ account: Account) async {
        _ = try? await call("auth/v1/logout?scope=local", token: account.token, body: Data("{}".utf8))
    }

    // MARK: Sessions

    public func push(_ sessions: [FocusSession], deviceID: String, token: String) async throws {
        struct Push: Encodable { var sessions: [FocusSession] }
        let body = try JSONEncoder.iso8601.encode(Push(sessions: sessions))
        _ = try await call("rest/v1/rpc/push_sessions", token: token, body: body)
    }

    public func pull(after cursor: String, token: String) async throws -> SyncPage {
        let body = try JSONEncoder().encode(["after": Int64(cursor) ?? 0])
        let data = try await call("rest/v1/rpc/pull_sessions", token: token, body: body)
        do { return try JSONDecoder.iso8601.decode(SyncPage.self, from: data) } catch { throw SyncError.unreachable }
    }

    // MARK: Plumbing

    private func tokens(_ path: String, _ fields: [String: String]) async throws -> Account {
        try account(from: try await call(path, body: try JSONEncoder().encode(fields)))
    }

    private func account(from data: Data) throws -> Account {
        struct Tokens: Decodable {
            struct User: Decodable { var email: String? }
            var access_token: String
            var refresh_token: String
            var expires_in: TimeInterval
            var user: User
        }
        guard let t = try? JSONDecoder().decode(Tokens.self, from: data) else { throw SyncError.unreachable }
        return Account(username: Self.username(from: t.user.email ?? ""), token: t.access_token,
                       refreshToken: t.refresh_token, expiresAt: Date().addingTimeInterval(t.expires_in))
    }

    /// Auth errors come as `{ code: 400, error_code, msg }` (older ones as
    /// `{ error, error_description }`), database errors as `{ code: "42501",
    /// message }`.
    private static func failure(_ data: Data) -> (code: String?, message: String) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = json?["error_code"] as? String ?? json?["error"] as? String ?? json?["code"] as? String
        let message = json?["msg"] as? String ?? json?["message"] as? String
            ?? json?["error_description"] as? String ?? ""
        return (code, message)
    }

    private func call(_ path: String, token: String? = nil, body: Data, signingUp: Bool = false) async throws -> Data {
        // Joined as text: `appending(path: "/")` doubles the slash on macOS 15.
        let base = project.absoluteString.hasSuffix("/") ? String(project.absoluteString.dropLast()) : project.absoluteString
        guard let url = URL(string: base + "/" + path) else {
            throw SyncError.unreachable
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if 200..<300 ~= status { return data }

        let (code, message) = Self.failure(data)
        // The profile trigger rejecting a name (a race with the live check).
        if signingUp, message.contains("Database error") { throw SyncError.rejected(Self.taken) }
        switch (status, code) {
        case (401, _) where token != nil, (403, "28000"):
            throw SyncError.signedOut
        case (_, let code?):
            if let sentence = Self.sentences[code] { throw SyncError.rejected(sentence) }
            if status >= 500 { throw SyncError.unreachable }
            throw SyncError.rejected("something went wrong. try again.")
        default:
            if status == 429 { throw SyncError.rejected(Self.tooMany) }
            throw SyncError.unreachable
        }
    }

    private static let taken = "that username is taken"
    private static let tooMany = "too many tries. give it a minute."

    /// Supabase's error codes, in the apps' words.
    private static let sentences: [String: String] = [
        "invalid_credentials": "wrong username or password",
        "invalid_grant": "wrong username or password",
        "user_already_exists": taken,
        "email_exists": taken,
        "weak_password": "use at least 8 characters",
        "email_address_invalid": "that username doesn't look right",
        "validation_failed": "that username doesn't look right",
        "signup_disabled": "sign-ups are closed for now",
        "over_request_rate_limit": tooMany,
        "22023": "couldn't sync. try updating the app.",
    ]
}

/// Tokens expire after an hour; the refresh token gets the next one.
public struct Account: Codable, Equatable, Sendable {
    public var username: String
    public var token: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(username: String, token: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.username = username
        self.token = token
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
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
    /// A sentence fit to show, like "wrong username or password".
    case rejected(String)
}

extension JSONEncoder {
    /// Dates as ISO 8601, as the RPCs expect.
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
