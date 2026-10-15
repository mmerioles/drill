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

    /// Tokens this close to running out are swapped before a sync.
    private static let margin: TimeInterval = 5 * 60

    // MARK: Accounts

    public func signIn(email: String, password: String) async throws -> Account {
        try await tokens("auth/v1/token?grant_type=password", ["email": email, "password": password])
    }

    public func createAccount(email: String, password: String) async throws -> Account {
        let body = try JSONEncoder().encode(["email": email, "password": password])
        return try account(from: try await call("auth/v1/signup", body: body, signingUp: true))
    }

    /// The live check while typing.
    public func emailAvailable(_ email: String) async throws -> Bool {
        let body = try JSONEncoder().encode(["email": email])
        let data = try await call("rest/v1/rpc/email_available", body: body)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// The same account unless its token is about to expire, or `force`
    /// says to swap it anyway. A new token brings the account's email.
    public func refreshed(_ account: Account, force: Bool) async throws -> Account {
        guard let refresh = account.refreshToken else { throw SyncError.signedOut }
        if !force, let expiresAt = account.expiresAt, expiresAt.timeIntervalSinceNow > Self.margin {
            return account
        }
        do {
            var fresh = try await tokens("auth/v1/token?grant_type=refresh_token", ["refresh_token": refresh])
            if fresh.email.isEmpty { fresh.email = account.email }
            return fresh
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
        return Account(email: t.user.email ?? "", token: t.access_token,
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
        // A taken email, as some Auth versions say it.
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

    private static let taken = "an account with this email already exists"
    private static let tooMany = "too many tries. give it a minute."

    /// Supabase's error codes, in the apps' words.
    private static let sentences: [String: String] = [
        "invalid_credentials": "wrong email or password",
        "invalid_grant": "wrong email or password",
        "user_already_exists": taken,
        "email_exists": taken,
        "weak_password": "use at least 6 characters",
        "email_address_invalid": "that email doesn't look right",
        "validation_failed": "that email doesn't look right",
        "signup_disabled": "sign-ups are closed for now",
        "over_request_rate_limit": tooMany,
        "22023": "couldn't sync. try updating the app.",
    ]
}

/// Tokens expire after an hour; the refresh token gets the next one.
public struct Account: Codable, Equatable, Sendable {
    public var email: String
    public var token: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(email: String, token: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.email = email
        self.token = token
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Kept by a version with usernames, which stored the name; Auth knew
    /// it as name@users.mmerioles.github.io until the switch to emails.
    public var isLegacy: Bool { email.hasSuffix("@" + Self.legacyDomain) }

    private static let legacyDomain = "users.mmerioles.github.io"

    private enum CodingKeys: String, CodingKey { case email, username, token, refreshToken, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let email = try c.decodeIfPresent(String.self, forKey: .email) {
            self.email = email
        } else {
            self.email = try c.decode(String.self, forKey: .username) + "@" + Self.legacyDomain
        }
        token = try c.decode(String.self, forKey: .token)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(email, forKey: .email)
        try c.encode(token, forKey: .token)
        try c.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }

    /// The Supabase user id, the access token's `sub`. Every token the
    /// account gets carries the same one. The email for a token that
    /// isn't a JWT.
    public var userID: String {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return email }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sub = claims["sub"] as? String, !sub.isEmpty
        else { return email }
        return sub.lowercased()
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
    /// A sentence fit to show, like "wrong email or password".
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
