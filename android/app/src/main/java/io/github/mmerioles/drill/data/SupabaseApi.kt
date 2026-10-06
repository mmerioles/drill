package io.github.mmerioles.drill.data

import io.github.mmerioles.drill.core.FocusSession
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * drill's hosted sync, like SupabaseAPI.swift: Supabase Auth for accounts,
 * and the two functions in supabase/migrations for sessions. Same contract
 * as a self-hosted server (docs/SYNC.md), so [Sync] doesn't care which one
 * it's talking to.
 *
 * The publishable key is meant to ship inside apps. It can only sign people
 * up and call the functions as whoever signed in; the database keeps each
 * account to its own rows.
 */
class SupabaseApi(private val project: String, private val key: String) : SyncBackend {
    override fun signIn(email: String, password: String): Account =
        tokens("auth/v1/token?grant_type=password", JSONObject().put("email", email).put("password", password))

    /** Supabase answers a taken email the same as a new one, so nobody can
     *  probe who has an account, except that the user it sends back has no
     *  identities. */
    override fun createAccount(email: String, password: String): SignUp {
        val reply = call("auth/v1/signup?redirect_to=$REDIRECT", body = JSONObject().put("email", email).put("password", password))
        if (reply.has("access_token")) return SignUp.SignedIn(account(reply)) // confirmation is off
        if (reply.optJSONArray("identities")?.length() == 0) {
            throw SyncBackend.Rejected("there's already an account with that email")
        }
        val id = reply.optString("id").ifEmpty { throw IOException("no user id") }
        return SignUp.ConfirmByLink(id)
    }

    /** The answer is a bare `true` or `false`, not an object. */
    override fun isConfirmed(userID: String): Boolean =
        request("rest/v1/rpc/email_confirmed", body = JSONObject().put("user_id", userID)).trim() == "true"

    override fun resendLink(email: String) {
        call("auth/v1/resend?redirect_to=$REDIRECT", body = JSONObject().put("type", "signup").put("email", email))
    }

    override fun refreshed(account: Account, force: Boolean): Account {
        val refresh = account.refreshToken ?: throw SyncBackend.SignedOut()
        val expiresAt = account.expiresAt
        if (!force && expiresAt != null && expiresAt - System.currentTimeMillis() > MARGIN) return account
        return try {
            tokens("auth/v1/token?grant_type=refresh_token", JSONObject().put("refresh_token", refresh))
        } catch (e: SyncBackend.Rejected) {
            throw SyncBackend.SignedOut() // the refresh token was used up or revoked
        }
    }

    override fun signOut(account: Account) {
        runCatching { call("auth/v1/logout?scope=local", token = account.token, body = JSONObject()) }
    }

    override fun push(sessions: List<FocusSession>, deviceID: String, token: String) {
        val rows = JSONArray()
        sessions.forEach { rows.put(SyncApi.encode(it)) }
        call("rest/v1/rpc/push_sessions", token = token, body = JSONObject().put("sessions", rows))
    }

    override fun pull(cursor: String, token: String): Page {
        val json = call("rest/v1/rpc/pull_sessions", token = token,
            body = JSONObject().put("after", cursor.toLongOrNull() ?: 0L))
        return try {
            val rows = json.getJSONArray("sessions")
            Page(List(rows.length()) { SyncApi.decode(rows.getJSONObject(it)) }, json.getString("cursor"), json.optBoolean("more"))
        } catch (e: JSONException) {
            throw IOException(e)
        }
    }

    private fun tokens(path: String, body: JSONObject): Account = account(call(path, body = body))

    private fun account(json: JSONObject): Account = try {
        val user = json.getJSONObject("user")
        Account(
            email = user.optString("email"),
            token = json.getString("access_token"),
            confirmed = !user.isNull("email_confirmed_at"),
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
        val conn = URL("$project/$path").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.useCaches = false
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Accept", "application/json")
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("apikey", key)
            token?.let { conn.setRequestProperty("Authorization", "Bearer $it") }
            conn.outputStream.use { it.write(body.toString().toByteArray()) }

            val status = conn.responseCode
            val text = (if (status >= 400) conn.errorStream else conn.inputStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (status in 200..299) return text
            val json = runCatching { JSONObject(text) }.getOrElse { JSONObject() }

            val code = listOf("error_code", "error", "code").firstNotNullOfOrNull { k ->
                json.opt(k)?.takeIf { it is String }?.toString()
            }
            when {
                code == "email_not_confirmed" || (status == 403 && code == "42501") -> throw SyncBackend.Unconfirmed()
                (status == 401 && token != null) || (status == 403 && code == "28000") -> throw SyncBackend.SignedOut()
                code != null -> {
                    SENTENCES[code]?.let { throw SyncBackend.Rejected(it) }
                    if (status >= 500) throw IOException("server error $status")
                    throw SyncBackend.Rejected("something went wrong. try again.")
                }
                status == 429 -> throw SyncBackend.Rejected(TOO_MANY)
                else -> throw IOException("server error $status")
            }
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        val hosted = SupabaseApi(
            "https://fgqtpetuzseozttapzem.supabase.co",
            "sb_publishable_WeTl_T2-z_i1ycA7KSgCyQ_9a64WoAg",
        )

        /** Where the link in the confirmation email lands. Supabase only goes
         *  there when it's on the same site as the project's Site URL. */
        const val CONFIRMED_PAGE = "https://mmerioles.github.io/drill/confirmed/"
        private val REDIRECT = URLEncoder.encode(CONFIRMED_PAGE, "UTF-8")

        /** Tokens this close to running out are swapped before a sync. */
        private const val MARGIN = 5 * 60 * 1000L

        private const val TOO_MANY = "too many tries. wait a minute and try again."

        /** Supabase's error codes, in the apps' words. */
        private val SENTENCES = mapOf(
            "invalid_credentials" to "wrong email or password",
            "invalid_grant" to "wrong email or password",
            "user_already_exists" to "there's already an account with that email",
            "email_exists" to "there's already an account with that email",
            "weak_password" to "use at least 8 characters for the password",
            "email_address_invalid" to "that email doesn't look right",
            "validation_failed" to "that email doesn't look right",
            "signup_disabled" to "new accounts are closed for now",
            "over_email_send_rate_limit" to "we just sent you one. give it a minute before asking for another.",
            "over_request_rate_limit" to TOO_MANY,
            "22023" to "this device has a session the server can't take. update the app.",
        )
    }
}
