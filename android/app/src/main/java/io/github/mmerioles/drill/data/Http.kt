package io.github.mmerioles.drill.data

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** A blocking JSON request: POST with [body], else GET. Returns the status and the reply's text. */
internal fun httpJson(url: String, token: String? = null, body: JSONObject? = null, headers: Map<String, String> = emptyMap()): Pair<Int, String> {
    val conn = URL(url).openConnection() as HttpURLConnection
    try {
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        conn.useCaches = false
        conn.setRequestProperty("Accept", "application/json")
        headers.forEach(conn::setRequestProperty)
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
        return status to text
    } finally {
        conn.disconnect()
    }
}
