package io.github.mmerioles.drill.data

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
import io.github.mmerioles.drill.BuildConfig
import io.github.mmerioles.drill.DrillApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** Updates the app from GitHub releases: downloads the newest apk and hands it to Android's installer. */
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

    val available get() = (state as? State.Available)?.release
        ?: (state as? State.Failed)?.let { lastFound }
    private var lastFound: Release? = null

    private var started = false
    /** Sent to Android's "install unknown apps" switch; [resume] carries on. */
    private var awaitingPermission = false

    private var lastChecked = 0L

    /** Checks now, then hourly. */
    fun start() {
        if (started) return
        started = true
        scope.launch {
            while (true) {
                check()
                delay(3600_000L)
            }
        }
    }

    /** A quiet check, unless one ran within [ageMs]. */
    fun checkIfStale(ageMs: Long = 60_000L) {
        if (state is State.Available) return
        if (System.currentTimeMillis() - lastChecked < ageMs) return
        scope.launch { check() }
    }

    /** A [manual] check spins for at least 900ms and reports failure; background checks fail quietly. */
    suspend fun check(manual: Boolean = false) {
        if (state is State.Checking || state is State.Downloading) return
        state = State.Checking
        lastChecked = System.currentTimeMillis()
        val settle = System.currentTimeMillis() + if (manual) 900 else 0
        val found = withContext(Dispatchers.IO) { runCatching { latest() } }
        delay(settle - System.currentTimeMillis())
        state = found.fold(
            onSuccess = { r ->
                lastFound = r
                if (r != null) State.Available(r) else State.UpToDate
            },
            onFailure = {
                when {
                    manual -> State.Failed("couldn't check for updates.")
                    lastFound != null -> State.Available(lastFound!!)
                    else -> State.Idle
                }
            },
        )
    }

    fun failed(message: String) {
        state = State.Failed(message)
    }

    fun install() {
        val release = available ?: return
        if (!context.packageManager.canRequestPackageInstalls()) {
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
                    session.openWrite("drill.apk", 0, conn.contentLengthLong).use { out ->
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
        private const val LATEST = "https://api.github.com/repos/mmerioles/drill/releases/latest"

        /** Compares x.y.z versions. */
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

/** The installer's callback: shows its confirm screen, or reports a failure. */
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
            else -> DrillApp.model(context).updater.failed("the update didn't install. try again.")
        }
    }
}
