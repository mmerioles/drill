package io.github.mmerioles.drill.data

import io.github.mmerioles.drill.core.FocusSession
import io.github.mmerioles.drill.core.WireDate
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder

/** Who you're signed in as. Hosted tokens run out after an hour and come
 *  with a refresh token to get the next one; self-hosted ones never run out. */
data class Account(
    val email: String,
    val token: String,
    val confirmed: Boolean,
    val refreshToken: String? = null,
    /** Epoch millis. */
    val expiresAt: Long? = null,
)

/** One page of a pull: rows after the cursor, the cursor to pull from next,
 *  and whether there's more. */
data class Page(val sessions: List<FocusSession>, val cursor: String, val more: Boolean)

/** How making an account went. */
sealed interface SignUp {
    /** Ready to sync. */
    data class SignedIn(val account: Account) : SignUp
    /** Waiting on the link in the confirmation email; sign in once
     *  [SyncBackend.isConfirmed] says so. */
    data class ConfirmByLink(val userID: String) : SignUp
}

/** Where an account lives: drill's hosted sync ([SupabaseApi]) or a
 *  self-hosted server ([SyncApi]), like SyncBackend in SyncAPI.swift.
 *  Blocking; call off the main thread. Unreachable is an IOException. */
interface SyncBackend {
    fun signIn(email: String, password: String): Account
    fun createAccount(email: String, password: String): SignUp
    /** Whether the account made by [createAccount] has had its email link
     *  clicked yet. */
    fun isConfirmed(userID: String): Boolean
    /** Sends the confirmation email again. */
    fun resendLink(email: String)
    /** The account with a token good for a while yet: the same one unless
     *  it's about to run out, or [force] says the server turned it down. */
    fun refreshed(account: Account, force: Boolean): Account
    /** Best effort: signing out here never waits on it. */
    fun signOut(account: Account)
    fun push(sessions: List<FocusSession>, deviceID: String, token: String)
    fun pull(cursor: String, token: String): Page

    /** The server said no, with a sentence fit to show. */
    class Rejected(message: String) : Exception(message)
    class SignedOut : Exception()
    class Unconfirmed : Exception()
}

/** A self-hosted server's calls, as in docs/SYNC.md and SyncAPI.swift. */
class SyncApi(private val server: String) : SyncBackend {
    override fun signIn(email: String, password: String): Account = account(call("v1/signin", body = credentials(email, password)))

    /** Always signed in: a self-hosted account syncs before it's confirmed,
     *  unless the server says otherwise. */
    override fun createAccount(email: String, password: String): SignUp =
        SignUp.SignedIn(account(call("v1/accounts", body = credentials(email, password))))

    override fun isConfirmed(userID: String): Boolean = true

    override fun resendLink(email: String): Unit =
        throw SyncBackend.Rejected("this server sends its own confirmation emails")

    override fun refreshed(account: Account, force: Boolean): Account {
        if (force) throw SyncBackend.SignedOut()
        return account
    }

    /** Revokes the token. */
    override fun signOut(account: Account) {
        runCatching { call("v1/signout", token = account.token, body = JSONObject()) }
    }

    private fun credentials(email: String, password: String) = JSONObject().put("email", email).put("password", password)

    private fun account(json: JSONObject) =
        Account(json.getString("email"), json.getString("token"), json.optBoolean("confirmed"))

    override fun push(sessions: List<FocusSession>, deviceID: String, token: String) {
        val rows = JSONArray()
        sessions.forEach { rows.put(encode(it)) }
        call("v1/sessions/push", token = token, body = JSONObject().put("deviceID", deviceID).put("sessions", rows))
    }

    override fun pull(cursor: String, token: String): Page {
        val json = call("v1/sessions/pull?cursor=${URLEncoder.encode(cursor, "UTF-8")}", token = token)
        val rows = json.getJSONArray("sessions")
        return Page(List(rows.length()) { decode(rows.getJSONObject(it)) }, json.getString("cursor"), json.optBoolean("more"))
    }

    private fun call(path: String, token: String? = null, body: JSONObject? = null): JSONObject {
        val conn = URL("$server/$path").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.useCaches = false
            conn.setRequestProperty("Accept", "application/json")
            token?.let { conn.setRequestProperty("Authorization", "Bearer $it") }
            if (body != null) {
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.outputStream.use { it.write(body.toString().toByteArray()) }
            }
            val status = conn.responseCode
            val text = (if (status >= 400) conn.errorStream else conn.inputStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            val json = runCatching { JSONObject(text) }.getOrElse { JSONObject() }
            when {
                status == 401 && token != null -> throw SyncBackend.SignedOut()
                status == 403 -> throw SyncBackend.Unconfirmed()
                status >= 400 -> throw SyncBackend.Rejected(json.optString("error").ifEmpty { "something went wrong. try again." })
            }
            return json
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        /** A server address as typed, cleaned up; https unless it says otherwise.
         *  Null when it can't be a server. */
        fun serverUrl(text: String): String? {
            var t = text.trim().trimEnd('/')
            if (t.isEmpty()) return null
            if ("://" !in t) t = "https://$t"
            val uri = runCatching { URI(t) }.getOrNull() ?: return null
            if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrEmpty()) return null
            return t
        }

        fun encode(s: FocusSession): JSONObject = JSONObject()
            .put("id", s.id)
            .put("startedAt", WireDate.format(s.startedAt))
            .put("endedAt", WireDate.format(s.endedAt))
            .put("focusSeconds", s.focusSeconds)
            .put("plannedSeconds", s.plannedSeconds)
            .put("completed", s.completed)
            .put("tag", s.tag ?: JSONObject.NULL)
            .put("deviceID", s.deviceID)
            .put("updatedAt", WireDate.format(s.updatedAt))
            .put("deletedAt", s.deletedAt?.let(WireDate::format) ?: JSONObject.NULL)

        fun decode(j: JSONObject) = FocusSession(
            id = j.getString("id").uppercase(),
            startedAt = WireDate.parse(j.getString("startedAt")),
            endedAt = WireDate.parse(j.getString("endedAt")),
            focusSeconds = j.getDouble("focusSeconds"),
            plannedSeconds = j.getDouble("plannedSeconds"),
            completed = j.getBoolean("completed"),
            tag = if (j.isNull("tag")) null else j.getString("tag"),
            deviceID = j.getString("deviceID"),
            updatedAt = WireDate.parse(j.getString("updatedAt")),
            deletedAt = if (j.isNull("deletedAt")) null else WireDate.parse(j.getString("deletedAt")),
        )
    }
}
