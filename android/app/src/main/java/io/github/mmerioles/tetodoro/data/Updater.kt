package io.github.mmerioles.tetodoro.data

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.mmerioles.tetodoro.BuildConfig
import io.github.mmerioles.tetodoro.TetodoroApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Keeps the app current from GitHub releases, like Updater.swift on the mac:
 * finds the newest release, downloads its apk, and hands it to Android's
 * installer, which asks once to confirm and then replaces this app in place.
 * Sessions and settings stay. The first time, Android also asks to let
 * tetodoro install apps.
 */
class Updater(private val context: Context, private val scope: CoroutineScope) {
    data class Release(val version: String, val apk: String)

    sealed interface State {
        data object Idle : State
        data object Checking : State
        data object UpToDate : State
        data class Available(val release: Release) : State
        data object Downloading : State
        data class Failed(val message: String) : State
    }

    var state by mutableStateOf<State>(State.Idle)
        private set

    /** A newer release, if one is known. */
    val available get() = (state as? State.Available)?.release
        ?: (state as? State.Failed)?.let { lastFound }
    private var lastFound: Release? = null

    private var started = false
    /** Sent to Android's install switch; carry on when back, if allowed. */
    private var awaitingPermission = false

    /** Checks now, then every few hours while the process lives. */
    fun start() {
        if (started) return
        started = true
        scope.launch {
            while (true) {
                check()
                delay(6 * 3600_000L)
            }
        }
    }

    suspend fun check() {
        if (state is State.Checking || state is State.Downloading) return
        state = State.Checking
        val found = withContext(Dispatchers.IO) { runCatching { latest() } }
        state = found.fold(
            onSuccess = { r ->
                lastFound = r
                if (r != null) State.Available(r) else State.UpToDate
            },
            onFailure = { State.Failed("can't check for updates.") },
        )
    }

    fun failed(message: String) {
        state = State.Failed(message)
    }

    /** Downloads the newer apk and opens the installer. */
    fun install() {
        val release = available ?: return
        if (!context.packageManager.canRequestPackageInstalls()) {
            // Android's switch for letting this app install updates. Coming
            // back with it on carries on (resume); with it off, nothing happens.
            awaitingPermission = true
            context.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return
        }
        state = State.Downloading
        scope.launch {
            val ok = withContext(Dispatchers.IO) { runCatching { stage(release) }.isSuccess }
            state = if (ok) State.Available(release) else State.Failed("the update didn't download. try again.")
        }
    }

    /** Back on screen: finish an update that was waiting on the install switch. */
    fun resume() {
        if (!awaitingPermission) return
        awaitingPermission = false
        if (context.packageManager.canRequestPackageInstalls()) install()
    }

    /** Streams the apk into an installer session and commits it. Blocking. */
    private fun stage(release: Release) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            try {
                val conn = URL(release.apk).openConnection() as HttpURLConnection
                conn.connectTimeout = 15_000
                conn.readTimeout = 60_000
                try {
                    if (conn.responseCode != 200) error("download failed: ${conn.responseCode}")
                    session.openWrite("tetodoro.apk", 0, conn.contentLengthLong).use { out ->
                        conn.inputStream.use { it.copyTo(out) }
                        session.fsync(out)
                    }
                } finally {
                    conn.disconnect()
                }
                val done = PendingIntent.getBroadcast(
                    context, id, Intent(context, InstallReceiver::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                session.commit(done.intentSender)
            } catch (e: Exception) {
                session.abandon()
                throw e
            }
        }
    }

    private fun latest(): Release? {
        val conn = URL(LATEST).openConnection() as HttpURLConnection
        conn.connectTimeout = 10_000
        conn.readTimeout = 15_000
        conn.setRequestProperty("Accept", "application/vnd.github+json")
        val json = try {
            if (conn.responseCode != 200) error("github said ${conn.responseCode}")
            JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
        } finally {
            conn.disconnect()
        }
        val version = json.getString("tag_name").removePrefix("v")
        val assets = json.getJSONArray("assets")
        val apk = (0 until assets.length()).map { assets.getJSONObject(it) }
            .firstOrNull { it.getString("name").endsWith(".apk") }
            ?.getString("browser_download_url") ?: return null
        return if (isNewer(version, BuildConfig.VERSION_NAME)) Release(version, apk) else null
    }

    companion object {
        private const val LATEST = "https://api.github.com/repos/mmerioles/tetodoro/releases/latest"

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
}

/** Hears back from the installer: shows its confirm screen when it needs
 *  one, and says so when an install fails. */
class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            PackageInstaller.STATUS_SUCCESS -> Unit // this process is replaced
            PackageInstaller.STATUS_FAILURE_ABORTED -> Unit // cancelled; update stays offered
            else -> TetodoroApp.model(context).updater.failed("the update didn't install. try again.")
        }
    }
}
