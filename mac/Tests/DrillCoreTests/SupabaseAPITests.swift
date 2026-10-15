import Foundation
import Testing
@testable import DrillCore

struct EmailTests {
    @Test func rule() {
        #expect(Email.isValid("teto@example.com"))
        #expect(Email.isValid("kasane.teto+drill@mail.example.co.jp"))
        #expect(Email.isValid("a@b.c"))
        #expect(!Email.isValid(""))
        #expect(!Email.isValid("teto"))
        #expect(!Email.isValid("teto@example"))
        #expect(!Email.isValid("@example.com"))
        #expect(!Email.isValid("teto@.com"))
        #expect(!Email.isValid("teto@@example.com"))
        #expect(!Email.isValid("te to@example.com"))
        #expect(!Email.isValid("teto@example.com\n"))
        let local = String(repeating: "a", count: 64)
        let long = local + "@" + String(repeating: "b", count: 254 - 64 - 1 - 4) + ".com"
        #expect(long.count == 254)
        #expect(Email.isValid(long))
        #expect(!Email.isValid("a" + long))
    }

    @Test func password() {
        #expect(!Password.isValid(""))
        #expect(!Password.isValid("12345"))
        #expect(Password.isValid("123456"))
        #expect(Password.isValid("a b é 🍅"))
        #expect(Password.isValid(String(repeating: "a", count: 72)))
        #expect(!Password.isValid(String(repeating: "a", count: 73)))
        #expect(!Password.isValid(String(repeating: "é", count: 37)))
        #expect(Password.confirms("kasane", "kasane"))
        #expect(!Password.confirms("kasane", "kasan"))
        #expect(!Password.confirms("teto", "teto"))
    }

    @Test func cleaning() {
        #expect(Email.clean(" Teto@Example.COM ") == "teto@example.com")
        #expect(Email.clean("kasane.teto+drill@example.com") == "kasane.teto+drill@example.com")
        #expect(Email.clean("a\tb@c.d\n") == "ab@c.d")
    }
}

struct AccountCodingTests {
    @Test func keptByTheUsernameVersion() throws {
        let old = #"{"username":"teto","token":"tok","refreshToken":"ref"}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(old.utf8))
        #expect(account.email == "teto@users.mmerioles.github.io")
        #expect(account.isLegacy)
        #expect(account.refreshToken == "ref")
    }

    @Test func roundTrips() throws {
        let account = Account(email: "teto@example.com", token: "tok", refreshToken: "ref",
                              expiresAt: Date(timeIntervalSince1970: 1_790_000_000))
        let data = try JSONEncoder().encode(account)
        #expect(try JSONDecoder().decode(Account.self, from: data) == account)
        #expect(!account.isLegacy)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["username"] == nil)
    }
}

/// SupabaseAPI against a stand-in: `Stub` answers every request from the
/// test's own reply, so these run offline and check the exact calls.
@Suite(.serialized) struct SupabaseAPIStubTests {
    let api: SupabaseAPI = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return SupabaseAPI(project: URL(string: "https://stub.test")!, key: "the-key",
                           session: URLSession(configuration: config))
    }()

    private static let tokens = """
        {"access_token":"tok","refresh_token":"ref","expires_in":3600,"token_type":"bearer",
         "user":{"id":"u1","email":"teto@example.com"}}
        """

    @Test func emailAvailable() async throws {
        Stub.reply = { _ in (200, "true") }
        #expect(try await api.emailAvailable("teto@example.com"))
        let sent = try #require(Stub.last)
        #expect(sent.request.url?.path == "/rest/v1/rpc/email_available")
        #expect(sent.request.value(forHTTPHeaderField: "apikey") == "the-key")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.json["email"] as? String == "teto@example.com")
        #expect(sent.json.count == 1)

        Stub.reply = { _ in (200, "false") }
        #expect(try await !api.emailAvailable("teto@example.com"))

        Stub.reply = { _ in (500, #"{"code":"XX000","message":"boom"}"#) }
        await #expect(throws: SyncError.unreachable) { try await api.emailAvailable("teto@example.com") }
    }

    @Test func signUpSendsTheEmailAndNothingElse() async throws {
        Stub.reply = { _ in (200, Self.tokens) }
        let me = try await api.createAccount(email: "teto@example.com", password: "kasane-0401")
        #expect(me.email == "teto@example.com")
        #expect(me.token == "tok")
        #expect(me.refreshToken == "ref")
        #expect(me.expiresAt.map { $0.timeIntervalSinceNow > 3500 } == true)

        let sent = try #require(Stub.last)
        #expect(sent.request.url?.path == "/auth/v1/signup")
        #expect(sent.request.url?.query == nil)
        #expect(sent.json["email"] as? String == "teto@example.com")
        #expect(sent.json["password"] as? String == "kasane-0401")
        #expect(sent.json.count == 2)
    }

    @Test func signUpRejections() async throws {
        Stub.reply = { _ in (500, #"{"code":500,"error_code":"unexpected_failure","msg":"Database error saving new user"}"#) }
        await #expect(throws: SyncError.rejected("an account with this email already exists")) {
            try await api.createAccount(email: "teto@example.com", password: "kasane-0401")
        }
        Stub.reply = { _ in (422, #"{"code":422,"error_code":"user_already_exists","msg":"User already registered"}"#) }
        await #expect(throws: SyncError.rejected("an account with this email already exists")) {
            try await api.createAccount(email: "teto@example.com", password: "kasane-0401")
        }
        Stub.reply = { _ in (422, #"{"code":422,"error_code":"weak_password","msg":"Password should be at least 6 characters."}"#) }
        await #expect(throws: SyncError.rejected("use at least 6 characters")) {
            try await api.createAccount(email: "teto@example.com", password: "short")
        }
        Stub.reply = { _ in (422, #"{"code":422,"error_code":"email_exists","msg":"Email address already registered"}"#) }
        await #expect(throws: SyncError.rejected("an account with this email already exists")) {
            try await api.createAccount(email: "teto@example.com", password: "kasane-0401")
        }
        Stub.reply = { _ in (400, #"{"code":400,"error_code":"email_address_invalid","msg":"Email address is invalid"}"#) }
        await #expect(throws: SyncError.rejected("that email doesn't look right")) {
            try await api.createAccount(email: "teto@example.com", password: "kasane-0401")
        }
    }

    @Test func signIn() async throws {
        Stub.reply = { _ in (200, Self.tokens) }
        let me = try await api.signIn(email: "teto@example.com", password: "kasane-0401")
        #expect(me.email == "teto@example.com")
        let sent = try #require(Stub.last)
        #expect(sent.request.url?.path == "/auth/v1/token")
        #expect(sent.request.url?.query == "grant_type=password")
        #expect(sent.json["email"] as? String == "teto@example.com")

        Stub.reply = { _ in (400, #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#) }
        await #expect(throws: SyncError.rejected("wrong email or password")) {
            try await api.signIn(email: "teto@example.com", password: "not-it")
        }
    }

    @Test func refreshTakesTheEmailFromTheUser() async throws {
        let old = Account(email: "teto@users.mmerioles.github.io", token: "old", refreshToken: "r0",
                          expiresAt: Date().addingTimeInterval(3600))
        Stub.reply = { _ in (200, Self.tokens) }
        #expect(try await api.refreshed(old, force: false) == old)
        let fresh = try await api.refreshed(old, force: true)
        #expect(fresh.email == "teto@example.com")
        #expect(!fresh.isLegacy)
        let sent = try #require(Stub.last)
        #expect(sent.request.url?.query == "grant_type=refresh_token")
        #expect(sent.json["refresh_token"] as? String == "r0")

        Stub.reply = { _ in (200, #"{"access_token":"t2","refresh_token":"r2","expires_in":3600,"user":{"id":"u1"}}"#) }
        #expect(try await api.refreshed(fresh, force: true).email == "teto@example.com")
    }

    @Test func revokedTokenSignsOut() async throws {
        Stub.reply = { _ in (401, #"{"code":401,"error_code":"bad_jwt","msg":"invalid JWT"}"#) }
        await #expect(throws: SyncError.signedOut) { try await api.pull(after: "0", token: "old") }
    }
}

/// Answers every request in a session made with it in `protocolClasses`.
final class Stub: URLProtocol {
    struct Sent {
        var request: URLRequest
        var body: Data
        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    nonisolated(unsafe) static var reply: (URLRequest) -> (status: Int, body: String) = { _ in (200, "") }
    nonisolated(unsafe) static var last: Sent?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.last = Sent(request: request, body: Self.body(of: request))
        let (status, body) = Self.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands protocols the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Runs SupabaseAPI against the hosted project, as an account that already
/// exists. Skipped unless DRILL_SUPABASE_TEST_EMAIL and
/// DRILL_SUPABASE_TEST_PASSWORD are set.
private let supabaseLogin: (email: String, password: String)? = {
    let env = ProcessInfo.processInfo.environment
    guard let email = env["DRILL_SUPABASE_TEST_EMAIL"], let password = env["DRILL_SUPABASE_TEST_PASSWORD"]
    else { return nil }
    return (email, password)
}()

@Suite(.serialized, .enabled(if: supabaseLogin != nil))
struct SupabaseAPILiveTests {
    let api = SupabaseAPI.hosted

    @Test func accountsAndSessionsRoundTrip() async throws {
        let (email, password) = try #require(supabaseLogin)
        let me = try await api.signIn(email: email, password: password)
        #expect(me.email == email)
        #expect(me.refreshToken != nil)
        #expect(try await api.refreshed(me, force: false) == me) // an hour left: kept

        let session = FocusSession(
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_001_500),
            focusSeconds: 1500, plannedSeconds: 1500, completed: true, tag: "15-213",
            deviceID: "mac", updatedAt: Date(timeIntervalSince1970: 1_790_001_500))
        try await api.push([session], deviceID: "mac", token: me.token)

        var page = try await api.pull(after: "0", token: me.token)
        #expect(page.sessions.contains(session))
        while page.more { page = try await api.pull(after: page.cursor, token: me.token) }
        #expect(try await api.pull(after: page.cursor, token: me.token).sessions.isEmpty)

        // A swapped token works; signing out ends the refresh token.
        let next = try await api.refreshed(me, force: true)
        #expect(next.token != me.token)
        #expect(try await api.pull(after: page.cursor, token: next.token).sessions.isEmpty)
        await api.signOut(next)
        await #expect(throws: SyncError.signedOut) { try await api.refreshed(next, force: true) }
    }

    @Test func friendlyRejections() async throws {
        let (email, password) = try #require(supabaseLogin)
        await #expect(throws: SyncError.rejected("wrong email or password")) {
            try await api.signIn(email: email, password: password + "-not-it")
        }
        await #expect(throws: SyncError.rejected("an account with this email already exists")) {
            try await api.createAccount(email: email, password: password)
        }
        await #expect(throws: SyncError.signedOut) { try await api.pull(after: "0", token: "not-a-token") }
        #expect(try await api.emailAvailable(email) == false)
        #expect(try await api.emailAvailable("drill-\(UUID().uuidString.prefix(8).lowercased())@example.com"))
    }
}
