import Foundation
import Testing
@testable import DrillCore

struct UsernameTests {
    @Test func rule() {
        #expect(Username.isValid("teto"))
        #expect(Username.isValid("kasane_0401"))
        #expect(Username.isValid("abc"))
        #expect(Username.isValid(String(repeating: "a", count: 20)))
        #expect(!Username.isValid(""))
        #expect(!Username.isValid("ab"))
        #expect(!Username.isValid(String(repeating: "a", count: 21)))
        #expect(!Username.isValid("Teto"))
        #expect(!Username.isValid("te to"))
        #expect(!Username.isValid("teto!"))
        #expect(!Username.isValid("tétö"))
        #expect(!Username.isValid("teto@users.mmerioles.github.io"))
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
        #expect(Username.clean(" Te To ") == "teto")
        #expect(Username.clean("KASANE_0401") == "kasane_0401")
        #expect(Username.clean("a\tb\nc") == "abc")
    }

    @Test func syntheticEmail() {
        #expect(SupabaseAPI.email(for: "teto") == "teto@users.mmerioles.github.io")
        #expect(SupabaseAPI.username(from: "teto@users.mmerioles.github.io") == "teto")
        #expect(SupabaseAPI.username(from: SupabaseAPI.email(for: "kasane_0401")) == "kasane_0401")
        #expect(SupabaseAPI.username(from: "") == "")
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
         "user":{"id":"u1","email":"teto@users.mmerioles.github.io"}}
        """

    @Test func usernameAvailable() async throws {
        Stub.reply = { _ in (200, "true") }
        #expect(try await api.usernameAvailable("teto"))
        let sent = try #require(Stub.last)
        #expect(sent.request.url?.path == "/rest/v1/rpc/username_available")
        #expect(sent.request.value(forHTTPHeaderField: "apikey") == "the-key")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.json["name"] as? String == "teto")
        #expect(sent.json.count == 1)

        Stub.reply = { _ in (200, "false") }
        #expect(try await !api.usernameAvailable("teto"))

        Stub.reply = { _ in (500, #"{"code":"XX000","message":"boom"}"#) }
        await #expect(throws: SyncError.unreachable) { try await api.usernameAvailable("teto") }
    }

    @Test func signUpSendsTheSyntheticEmailAndMetadata() async throws {
        Stub.reply = { _ in (200, Self.tokens) }
        let me = try await api.createAccount(username: "teto", password: "kasane-0401")
        #expect(me.username == "teto")
        #expect(me.token == "tok")
        #expect(me.refreshToken == "ref")
        #expect(me.expiresAt.map { $0.timeIntervalSinceNow > 3500 } == true)

        let sent = try #require(Stub.last)
        #expect(sent.request.url?.path == "/auth/v1/signup")
        #expect(sent.request.url?.query == nil)
        #expect(sent.json["email"] as? String == "teto@users.mmerioles.github.io")
        #expect(sent.json["password"] as? String == "kasane-0401")
        #expect(sent.json["data"] as? [String: String] == ["username": "teto"])
    }

    @Test func signUpRejections() async throws {
        Stub.reply = { _ in (500, #"{"code":500,"error_code":"unexpected_failure","msg":"Database error saving new user"}"#) }
        await #expect(throws: SyncError.rejected("that username is taken")) {
            try await api.createAccount(username: "teto", password: "kasane-0401")
        }
        Stub.reply = { _ in (422, #"{"code":422,"error_code":"user_already_exists","msg":"User already registered"}"#) }
        await #expect(throws: SyncError.rejected("that username is taken")) {
            try await api.createAccount(username: "teto", password: "kasane-0401")
        }
        Stub.reply = { _ in (422, #"{"code":422,"error_code":"weak_password","msg":"Password should be at least 6 characters."}"#) }
        await #expect(throws: SyncError.rejected("use at least 6 characters")) {
            try await api.createAccount(username: "teto", password: "short")
        }
    }

    @Test func signIn() async throws {
        Stub.reply = { _ in (200, Self.tokens) }
        let me = try await api.signIn(username: "teto", password: "kasane-0401")
        #expect(me.username == "teto")
        let sent = try #require(Stub.last)
        #expect(sent.request.url?.path == "/auth/v1/token")
        #expect(sent.request.url?.query == "grant_type=password")
        #expect(sent.json["email"] as? String == "teto@users.mmerioles.github.io")

        Stub.reply = { _ in (400, #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#) }
        await #expect(throws: SyncError.rejected("wrong username or password")) {
            try await api.signIn(username: "teto", password: "not-it")
        }
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
/// exists. Skipped unless DRILL_SUPABASE_TEST_USERNAME and
/// DRILL_SUPABASE_TEST_PASSWORD are set.
private let supabaseLogin: (username: String, password: String)? = {
    let env = ProcessInfo.processInfo.environment
    guard let username = env["DRILL_SUPABASE_TEST_USERNAME"], let password = env["DRILL_SUPABASE_TEST_PASSWORD"]
    else { return nil }
    return (username, password)
}()

@Suite(.serialized, .enabled(if: supabaseLogin != nil))
struct SupabaseAPILiveTests {
    let api = SupabaseAPI.hosted

    @Test func accountsAndSessionsRoundTrip() async throws {
        let (username, password) = try #require(supabaseLogin)
        let me = try await api.signIn(username: username, password: password)
        #expect(me.username == username)
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
        let (username, password) = try #require(supabaseLogin)
        await #expect(throws: SyncError.rejected("wrong username or password")) {
            try await api.signIn(username: username, password: password + "-not-it")
        }
        await #expect(throws: SyncError.rejected("that username is taken")) {
            try await api.createAccount(username: username, password: password)
        }
        await #expect(throws: SyncError.signedOut) { try await api.pull(after: "0", token: "not-a-token") }
        #expect(try await api.usernameAvailable(username) == false)
        #expect(try await api.usernameAvailable("no") == false) // too short
        #expect(try await api.usernameAvailable("drill_" + String(UUID().uuidString.prefix(8)).lowercased()))
    }
}
