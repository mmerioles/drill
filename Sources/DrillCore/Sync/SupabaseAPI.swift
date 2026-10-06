import Foundation

/// drill's hosted sync: Supabase Auth for accounts, and the two functions in
/// supabase/migrations for sessions. Same contract as a self-hosted server
/// (docs/SYNC.md), so `Sync` doesn't care which one it's talking to.
///
/// The publishable key is meant to ship inside apps. It can only sign people
/// up and call the functions as whoever signed in; the database keeps each
/// account to its own rows.
public struct SupabaseAPI: SyncBackend {
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

    /// Where the link in the confirmation email lands. Supabase only goes
    /// there when it's on the same site as the project's Site URL.
    public static let confirmedPage = "https://mmerioles.github.io/drill/confirmed/"

    /// Tokens this close to running out are swapped before a sync.
    private static let margin: TimeInterval = 5 * 60

    // MARK: Accounts

    public func signIn(email: String, password: String) async throws -> Account {
        try await tokens("auth/v1/token?grant_type=password", ["email": email, "password": password])
    }

    /// Supabase answers a taken email the same as a new one, so nobody can
    /// probe who has an account, except that the user it sends back has no
    /// identities.
    public func createAccount(email: String, password: String) async throws -> SignUp {
        struct Reply: Decodable {
            struct Identity: Decodable {}
            var id: String?
            var identities: [Identity]?
            var access_token: String?
        }
        let body = try JSONEncoder().encode(["email": email, "password": password])
        let data = try await call("auth/v1/signup?redirect_to=" + Self.redirect, body: body)
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if reply?.access_token != nil {
            return .signedIn(try account(from: data)) // confirmation is off
        }
        if reply?.identities?.isEmpty == true {
            throw SyncError.rejected("there's already an account with that email")
        }
        guard let id = reply?.id else { throw SyncError.unreachable }
        return .confirmByLink(userID: id)
    }

    public func isConfirmed(userID: String) async throws -> Bool {
        let body = try JSONEncoder().encode(["user_id": userID])
        let data = try await call("rest/v1/rpc/email_confirmed", body: body)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func resendLink(email: String) async throws {
        let body = try JSONEncoder().encode(["type": "signup", "email": email])
        _ = try await call("auth/v1/resend?redirect_to=" + Self.redirect, body: body)
    }

    private static let redirect = confirmedPage.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

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

    public func signOut(_ account: Account) async {
        _ = try? await call("auth/v1/logout?scope=local", token: account.token, body: Data("{}".utf8))
    }

    // MARK: Sessions

    public func push(_ sessions: [FocusSession], deviceID: String, token: String) async throws {
        struct Push: Encodable { var sessions: [FocusSession] }
        let body = try Self.encoder.encode(Push(sessions: sessions))
        _ = try await call("rest/v1/rpc/push_sessions", token: token, body: body)
    }

    public func pull(after cursor: String, token: String) async throws -> SyncPage {
        let body = try JSONEncoder().encode(["after": Int64(cursor) ?? 0])
        let data = try await call("rest/v1/rpc/pull_sessions", token: token, body: body)
        do { return try Self.decoder.decode(SyncPage.self, from: data) } catch { throw SyncError.unreachable }
    }

    // MARK: Plumbing

    private func tokens(_ path: String, _ fields: [String: String]) async throws -> Account {
        try account(from: try await call(path, body: try JSONEncoder().encode(fields)))
    }

    private func account(from data: Data) throws -> Account {
        struct Tokens: Decodable {
            struct User: Decodable { var email: String?; var email_confirmed_at: String? }
            var access_token: String
            var refresh_token: String
            var expires_in: TimeInterval
            var user: User
        }
        guard let t = try? JSONDecoder().decode(Tokens.self, from: data) else { throw SyncError.unreachable }
        return Account(email: t.user.email ?? "", token: t.access_token,
                       confirmed: t.user.email_confirmed_at != nil, refreshToken: t.refresh_token,
                       expiresAt: Date().addingTimeInterval(t.expires_in))
    }

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

    /// Auth errors come as `{ code: 400, error_code, msg }` (older ones as
    /// `{ error, error_description }`), database errors as `{ code: "42501",
    /// message }`.
    private static func errorCode(_ data: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["error_code"] as? String ?? json?["error"] as? String ?? json?["code"] as? String
    }

    private func call(_ path: String, token: String? = nil, body: Data) async throws -> Data {
        guard let url = URL(string: path, relativeTo: project.appending(path: "/")) else {
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

        switch (status, Self.errorCode(data)) {
        case (_, "email_not_confirmed"), (403, "42501"):
            throw SyncError.unconfirmed
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

    private static let tooMany = "too many tries. wait a minute and try again."

    /// Supabase's error codes, in the apps' words.
    private static let sentences: [String: String] = [
        "invalid_credentials": "wrong email or password",
        "invalid_grant": "wrong email or password",
        "user_already_exists": "there's already an account with that email",
        "email_exists": "there's already an account with that email",
        "weak_password": "use at least 8 characters for the password",
        "email_address_invalid": "that email doesn't look right",
        "validation_failed": "that email doesn't look right",
        "signup_disabled": "new accounts are closed for now",
        "over_email_send_rate_limit": "we just sent you one. give it a minute before asking for another.",
        "over_request_rate_limit": tooMany,
        "22023": "this device has a session the server can't take. update the app.",
    ]
}
