import Foundation
import Testing
@testable import DrillCore

/// Runs SupabaseAPI against the hosted project, as an account that already
/// exists and is confirmed (so no email goes out). Skipped unless
/// DRILL_SUPABASE_TEST_EMAIL and DRILL_SUPABASE_TEST_PASSWORD are set.
private let supabaseLogin: (email: String, password: String)? = {
    let env = ProcessInfo.processInfo.environment
    guard let email = env["DRILL_SUPABASE_TEST_EMAIL"], let password = env["DRILL_SUPABASE_TEST_PASSWORD"]
    else { return nil }
    return (email, password)
}()

@Suite(.serialized, .enabled(if: supabaseLogin != nil))
struct SupabaseAPITests {
    let api = SupabaseAPI.hosted

    @Test func accountsAndSessionsRoundTrip() async throws {
        let (email, password) = try #require(supabaseLogin)
        let me = try await api.signIn(email: email, password: password)
        #expect(me.email == email)
        #expect(me.confirmed)
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
        await #expect(throws: SyncError.rejected("there's already an account with that email")) {
            try await api.createAccount(email: email, password: password)
        }
        await #expect(throws: SyncError.signedOut) { try await api.pull(after: "0", token: "not-a-token") }
        #expect(try await api.isConfirmed(userID: UUID().uuidString) == false)
    }
}
