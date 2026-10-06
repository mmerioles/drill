package io.github.mmerioles.tetodoro.data

import io.github.mmerioles.tetodoro.core.FocusSession
import io.github.mmerioles.tetodoro.core.WireDate
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder

/** The calls in docs/SYNC.md, the same as SyncAPI.swift. Blocking; call off
 *  the main thread. */
class SyncApi(private val server: String) {
    data class Account(val email: String, val token: String, val confirmed: Boolean)
    data class Page(val sessions: List<FocusSession>, val cursor: String, val more: Boolean)

    /** The server said no, with a sentence fit to show. */
    class Rejected(message: String) : Exception(message)
    class SignedOut : Exception()
    class Unconfirmed : Exception()

    fun signIn(email: String, password: String, create: Boolean): Account {
        val body = JSONObject().put("email", email).put("password", password)
        val json = call(if (create) "v1/accounts" else "v1/signin", body = body)
        return Account(json.getString("email"), json.getString("token"), json.optBoolean("confirmed"))
    }

    /** Best effort: signing out here never waits on it. */
    fun signOut(token: String) {
        runCatching { call("v1/signout", token = token, body = JSONObject()) }
    }

    fun push(sessions: List<FocusSession>, deviceID: String, token: String) {
        val rows = JSONArray()
        sessions.forEach { rows.put(encode(it)) }
        call("v1/sessions/push", token = token, body = JSONObject().put("deviceID", deviceID).put("sessions", rows))
    }

    fun pull(cursor: String, token: String): Page {
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
                status == 401 && token != null -> throw SignedOut()
                status == 403 -> throw Unconfirmed()
                status >= 400 -> throw Rejected(json.optString("error").ifEmpty { "something went wrong. try again." })
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
