package io.github.mmerioles.tetodoro.data

import io.github.mmerioles.tetodoro.BuildConfig
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Looks for a newer release on GitHub, like Updater.swift on the mac. The
 * phone can't swap its own app, so an update is the newer apk's link: the
 * browser downloads it and Android offers to install it over this one.
 */
object Updater {
    data class Release(val version: String, val apk: String)

    private const val LATEST = "https://api.github.com/repos/mmerioles/tetodoro/releases/latest"

    /** The newest release, if it's newer than this build and has an apk. Blocking. */
    fun newer(): Release? = runCatching {
        val conn = URL(LATEST).openConnection() as HttpURLConnection
        conn.connectTimeout = 10_000
        conn.readTimeout = 15_000
        conn.setRequestProperty("Accept", "application/vnd.github+json")
        val json = try {
            if (conn.responseCode != 200) return null
            JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
        } finally {
            conn.disconnect()
        }
        val version = json.getString("tag_name").removePrefix("v")
        val assets = json.getJSONArray("assets")
        val apk = (0 until assets.length()).map { assets.getJSONObject(it) }
            .firstOrNull { it.getString("name").endsWith(".apk") }
            ?.getString("browser_download_url") ?: return null
        if (isNewer(version, BuildConfig.VERSION_NAME)) Release(version, apk) else null
    }.getOrNull()

    /** Semantic versions, compared part by part. */
    fun isNewer(version: String, than: String): Boolean {
        val a = parts(version) ?: return false
        val b = parts(than) ?: return true
        for (i in 0 until 3) if (a[i] != b[i]) return a[i] > b[i]
        return false
    }

    private fun parts(v: String): List<Int>? =
        v.split('.').map { it.toIntOrNull() ?: return null }.takeIf { it.size == 3 }
}
