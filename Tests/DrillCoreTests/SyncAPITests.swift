import Foundation
import Testing
@testable import DrillCore

/// Runs SyncAPI against the real server in web/server.py, so the two can't
/// drift apart. Needs python3, which macOS developer tools include.
@Suite(.serialized) struct SyncAPITests {
    @Test func accountsAndSessionsRoundTrip() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let api = SyncAPI(server: server.url)

        let me = try #require(await api.createAccount(email: "Teto@Example.test", password: "kasane-0401").account)
        #expect(me.email == "teto@example.test")
        #expect(me.confirmed == false)

        let session = FocusSession(
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_001_500),
            focusSeconds: 1500, plannedSeconds: 1500, completed: true, tag: "15-213",
            deviceID: "mac", updatedAt: Date(timeIntervalSince1970: 1_790_001_500))
        try await api.push([session], deviceID: "mac", token: me.token)

        let page = try await api.pull(after: "0", token: me.token)
        #expect(page.sessions == [session])
        #expect(page.more == false)
        #expect(try await api.pull(after: page.cursor, token: me.token).sessions.isEmpty)

        // Another account sees none of it.
        let other = try #require(await api.createAccount(email: "miku@example.test", password: "hatsune-0831").account)
        #expect(try await api.pull(after: "0", token: other.token).sessions.isEmpty)

        // Signing in again works; signing out ends that token.
        let again = try await api.signIn(email: "teto@example.test", password: "kasane-0401")
        await api.signOut(again)
        await #expect(throws: SyncError.signedOut) { try await api.pull(after: "0", token: again.token) }
    }

    @Test func friendlyRejections() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let api = SyncAPI(server: server.url)

        _ = try await api.createAccount(email: "teto@example.test", password: "kasane-0401")
        await #expect(throws: SyncError.rejected("wrong email or password")) {
            try await api.signIn(email: "teto@example.test", password: "not-it-at-all")
        }
        await #expect(throws: SyncError.rejected("there's already an account with that email")) {
            try await api.createAccount(email: "teto@example.test", password: "kasane-0401")
        }
        await #expect(throws: SyncError.rejected("use at least 8 characters for the password")) {
            try await api.createAccount(email: "new@example.test", password: "short")
        }
    }

    @Test func unreachableServer() async {
        let api = SyncAPI(server: URL(string: "http://127.0.0.1:9")!)
        await #expect(throws: SyncError.unreachable) { try await api.pull(after: "0", token: "x") }
    }

    @Test func serverAddresses() {
        #expect(SyncAPI.serverURL("teto.example.com")?.absoluteString == "https://teto.example.com")
        #expect(SyncAPI.serverURL(" https://teto.example.com/ ")?.absoluteString == "https://teto.example.com")
        #expect(SyncAPI.serverURL("http://192.168.1.4:8080")?.absoluteString == "http://192.168.1.4:8080")
        #expect(SyncAPI.serverURL("") == nil)
        #expect(SyncAPI.serverURL("ftp://teto.example.com") == nil)
    }
}

private extension SignUp {
    var account: Account? { if case .signedIn(let account) = self { account } else { nil } }
}

/// web/server.py on a free port with a throwaway data folder.
private final class TestServer {
    let url: URL
    private let process = Process()
    private let data: URL

    private init(port: Int) throws {
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        data = FileManager.default.temporaryDirectory.appending(path: "drill-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        url = URL(string: "http://127.0.0.1:\(port)")!

        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["python3", repo.appending(path: "web/server.py").path]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PORT": "\(port)", "DRILL_DATA": data.path]) { $1 }
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
    }

    static func start() async throws -> TestServer {
        let server = try TestServer(port: Int.random(in: 20_000..<60_000))
        let health = server.url.appending(path: "healthz")
        for _ in 0..<100 {
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 { return server }
            try await Task.sleep(for: .milliseconds(50))
        }
        server.stop()
        throw URLError(.cannotConnectToHost)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: data)
    }
}
