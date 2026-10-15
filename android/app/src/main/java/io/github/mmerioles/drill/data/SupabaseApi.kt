package io.github.mmerioles.drill.data

import io.github.mmerioles.drill.core.FocusSession
import io.github.mmerioles.drill.core.Username
import io.github.mmerioles.drill.core.WireDate
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException

/** Who you're signed in as. Tokens run out after an hour and come with a
 *  refresh token to get the next one. */
data class Account(
    val username: String,
    /** Supabase's user id; names the account's local store. */
    val userID: String,
    val token: String,
    val refreshToken: String,
    /** Epoch millis. */
    val expiresAt: Long,
)

/** One page of a pull: rows after the cursor, the cursor to pull from next,
 *  and whether there's more. */
data class Page(val sessions: List<FocusSession>, val cursor: String, val more: Boolean)

/**
 * drill's sync: Supabase Auth for accounts (signed up with a synthetic email,
 * see [Username]), and the functions in supabase/migrations for the rest. The
 * publishable key is meant to ship in apps; row-level security keeps each
 * account to its own rows. Blocking; unreachable is an IOException.
 */
class SupabaseApi(private val project: String, private val key: String) {
    /** The server said no, with a sentence fit to show. */
    class Rejected(message: String) : Exception(message)
    class SignedOut : Exception()

    fun signIn(username: String, password: String): Account =
        tokens("auth/v1/token?grant_type=password", JSONObject().put("email", Username.email(username)).put("password", password))

    /** The username rides along as metadata; a trigger makes the profile. */
    fun createAccount(username: String, password: String): Account =
        tokens("auth/v1/signup", JSONObject()
            .put("email", Username.email(username))
            .put("password", password)
            .put("data", JSONObject().put("username", username)))

    /** The answer is a bare `true` or `false`, not an object. */
    fun usernameAvailable(name: String): Boolean =
        request("rest/v1/rpc/username_available", body = JSONObject().put("name", name)).trim() == "true"

    /** The account with a token good for a while yet: the same one unless
     *  it's about to run out, or [force] says the server turned it down. */
    fun refreshed(account: Account, force: Boolean): Account {
        if (!force && account.expiresAt - System.currentTimeMillis() > MARGIN) return account
        return try {
            tokens("auth/v1/token?grant_type=refresh_token", JSONObject().put("refresh_token", account.refreshToken))
        } catch (e: Rejected) {
            throw SignedOut() // the refresh token was used up or revoked
        }
    }

    /** Best effort: signing out never waits on it. */
    fun signOut(account: Account) {
        runCatching { call("auth/v1/logout?scope=local", token = account.token, body = JSONObject()) }
    }

    fun push(sessions: List<FocusSession>, token: String) {
        val rows = JSONArray()
        sessions.forEach { rows.put(encode(it)) }
        call("rest/v1/rpc/push_sessions", token = token, body = JSONObject().put("sessions", rows))
    }

    fun pull(cursor: String, token: String): Page {
        val json = call("rest/v1/rpc/pull_sessions", token = token,
            body = JSONObject().put("after", cursor.toLongOrNull() ?: 0L))
        return try {
            val rows = json.getJSONArray("sessions")
            Page(List(rows.length()) { decode(rows.getJSONObject(it)) }, json.getString("cursor"), json.optBoolean("more"))
        } catch (e: JSONException) {
            throw IOException(e)
        }
    }

    private fun tokens(path: String, body: JSONObject): Account = try {
        val json = call(path, body = body)
        Account(
            username = Username.fromEmail(json.getJSONObject("user").getString("email")),
            userID = json.getJSONObject("user").getString("id"),
            token = json.getString("access_token"),
            refreshToken = json.getString("refresh_token"),
            expiresAt = System.currentTimeMillis() + json.getLong("expires_in") * 1000,
        )
    } catch (e: JSONException) {
        throw IOException(e)
    }

    /** Auth errors come as `{ error_code, msg }` (older ones as `{ error,
     *  error_description }`), database errors as `{ code, message }`. */
    private fun call(path: String, token: String? = null, body: JSONObject): JSONObject {
        val text = request(path, token, body)
        // A bare number (push's count) isn't an object; nobody reads it.
        return runCatching { JSONObject(text) }.getOrElse { JSONObject() }
    }

    /** The reply's text on success; on failure, the exception that fits. */
    private fun request(path: String, token: String? = null, body: JSONObject): String {
        val (status, text) = httpJson("$project/$path", token, body, headers = mapOf("apikey" to key))
        if (status in 200..299) return text
        val json = runCatching { JSONObject(text) }.getOrElse { JSONObject() }
        val code = listOf("error_code", "error", "code").firstNotNullOfOrNull { k ->
            json.opt(k)?.takeIf { it is String }?.toString()
        }
        val message = listOf("msg", "message", "error_description").firstNotNullOfOrNull { json.optString(it).ifEmpty { null } }
        when {
            (status == 401 && token != null) || (status == 403 && code == "28000") -> throw SignedOut()
            // The profile trigger refusing a taken name fails the whole sign-up.
            message?.contains("Database error") == true -> throw Rejected(TAKEN)
            code != null -> {
                SENTENCES[code]?.let { throw Rejected(it) }
                if (status >= 500) throw IOException("server error $status")
                throw Rejected("something went wrong. try again.")
            }
            status == 429 -> throw Rejected(TOO_MANY)
            else -> throw IOException("server error $status")
        }
    }

    companion object {
        val hosted = SupabaseApi(
            "https://fgqtpetuzseozttapzem.supabase.co",
            "sb_publishable_WeTl_T2-z_i1ycA7KSgCyQ_9a64WoAg",
        )

        /** Tokens this close to running out are swapped before a sync. */
        private const val MARGIN = 5 * 60 * 1000L

        private const val TAKEN = "that username is taken"
        private const val TOO_MANY = "too many tries. give it a minute."

        /** Supabase's error codes, in the apps' words. */
        private val SENTENCES = mapOf(
            "invalid_credentials" to "wrong username or password",
            "invalid_grant" to "wrong username or password",
            "user_already_exists" to TAKEN,
            "email_exists" to TAKEN,
            "weak_password" to "use at least 6 characters",
            "signup_disabled" to "sign-ups are closed for now",
            "over_request_rate_limit" to TOO_MANY,
            "22023" to "couldn't sync. try updating the app.",
        )

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
