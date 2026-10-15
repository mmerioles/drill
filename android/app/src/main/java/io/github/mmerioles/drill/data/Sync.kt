package io.github.mmerioles.drill.data

import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The account and the sync loop (docs/SYNC.md): push what changed here, then pull what changed elsewhere. */
class Sync(
    private val store: SessionStore,
    private val deviceID: String,
    private val prefs: SharedPreferences,
    private val scope: CoroutineScope,
    private val onPulled: () -> Unit,
) {
    enum class State { SignedOut, Idle, Syncing, Offline }

    var account by mutableStateOf(loadAccount())
        private set
    var state by mutableStateOf(if (account == null) State.SignedOut else State.Idle)
        private set
    /** Local changes not yet pushed. */
    var unpushed by mutableStateOf(0)
        private set
    /** Off: only signing in and the sync link sync. */
    var auto by mutableStateOf(prefs.getBoolean(Keys.AUTO, true))
        private set

    private val api = SupabaseApi.hosted
    private var running: Job? = null
    private var lastStarted = 0L

    val isSignedIn get() = account != null

    init {
        scope.launch { recount() }
    }

    fun updateAuto(on: Boolean) {
        auto = on
        prefs.edit().putBoolean(Keys.AUTO, on).apply()
        if (on) syncNow()
    }

    suspend fun recount() {
        withContext(Dispatchers.IO) { runCatching { store.unpushed() } }.onSuccess { unpushed = it }
    }

    fun autoSync() {
        if (auto) syncNow()
    }

    // Each returns null, or a sentence to show.

    suspend fun signIn(username: String, password: String): String? = problem {
        begin(attempt { api.signIn(username, password) })
    }

    suspend fun createAccount(username: String, password: String): String? = problem {
        begin(attempt { api.createAccount(username, password) })
    }

    /** Null when the server couldn't be asked. */
    suspend fun usernameAvailable(name: String): Boolean? = try {
        withContext(Dispatchers.IO) { api.usernameAvailable(name) }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    /** Everything already on this phone joins the account. */
    private suspend fun begin(account: Account) {
        save(account)
        withContext(Dispatchers.IO) { store.markAllDirty() }
        prefs.edit().putString(Keys.CURSOR, "0").apply()
        state = State.Idle
        syncNow()
    }

    private class Problem(message: String) : Exception(message)

    /** Runs [call] on IO, turning failures into [Problem]s. */
    private suspend fun <T> attempt(call: () -> T): T = try {
        withContext(Dispatchers.IO) { call() }
    } catch (e: CancellationException) {
        throw e
    } catch (e: SupabaseApi.Rejected) {
        throw Problem(e.message ?: "something went wrong. try again.")
    } catch (e: Exception) {
        throw Problem("can't connect. try again in a bit.")
    }

    private suspend fun problem(work: suspend () -> Unit): String? = try {
        work()
        null
    } catch (e: Problem) {
        e.message
    }

    fun signOut() {
        val account = account
        if (account != null) {
            scope.launch(Dispatchers.IO) { api.signOut(account) }
        }
        running?.cancel()
        running = null
        save(null)
        state = State.SignedOut
    }

    fun syncNow() {
        val account = account ?: return
        if (running?.isActive == true) return
        lastStarted = System.currentTimeMillis()
        running = scope.launch { run(account) }
    }

    fun cameBack() {
        if (System.currentTimeMillis() - lastStarted >= 20_000L) autoSync()
    }

    suspend fun settle() {
        running?.join()
    }

    private suspend fun run(start: Account) {
        state = State.Syncing
        var token = start.token
        try {
            val pulled = withContext(Dispatchers.IO) {
                // Tokens last an hour: swap one that's nearly out, and once
                // more if the server turns it down anyway.
                token = fresh(start, force = false)
                try {
                    exchange(token)
                } catch (e: SupabaseApi.SignedOut) {
                    token = fresh(start, force = true)
                    exchange(token)
                }
            }
            if (pulled) onPulled()
            if (account?.token != token) return // signed out meanwhile
            state = State.Idle
        } catch (e: SupabaseApi.SignedOut) {
            if (account?.username != start.username) return
            save(null)
            state = State.SignedOut
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // A bad page, an unparseable date, the disk: call it offline and retry next time.
            if (account?.username == start.username) state = State.Offline
        }
        recount()
    }

    private suspend fun fresh(start: Account, force: Boolean): String {
        val current = account ?: start
        val fresh = api.refreshed(current, force)
        if (fresh != current) withContext(Dispatchers.Main) { if (account?.username == start.username) save(fresh) }
        return fresh.token
    }

    /** Returns true when the pull brought anything down. */
    private fun exchange(token: String): Boolean {
        store.dirty().chunked(200).forEach { batch ->
            api.push(batch, token)
            store.pushed(batch)
        }
        var pulled = false
        do {
            val page = api.pull(prefs.getString(Keys.CURSOR, "0")!!, token)
            if (store.save(page.sessions, local = false) > 0) pulled = true
            prefs.edit().putString(Keys.CURSOR, page.cursor).apply()
        } while (page.more)
        return pulled
    }

    private fun loadAccount(): Account? {
        val username = prefs.getString(Keys.USERNAME, null) ?: return null
        val token = prefs.getString(Keys.TOKEN, null) ?: return null
        val refresh = prefs.getString(Keys.REFRESH, null) ?: return null
        return Account(username, token, refresh, prefs.getLong(Keys.EXPIRES, 0L))
    }

    private fun save(account: Account?) {
        this.account = account
        prefs.edit().apply {
            if (account == null) {
                remove(Keys.USERNAME); remove(Keys.TOKEN); remove(Keys.REFRESH); remove(Keys.EXPIRES)
            } else {
                putString(Keys.USERNAME, account.username)
                putString(Keys.TOKEN, account.token)
                putString(Keys.REFRESH, account.refreshToken)
                putLong(Keys.EXPIRES, account.expiresAt)
            }
        }.apply()
    }

    private object Keys {
        const val USERNAME = "sync.username"
        const val TOKEN = "sync.token"
        const val REFRESH = "sync.refreshToken"
        const val EXPIRES = "sync.expiresAt" // epoch millis
        const val CURSOR = "sync.cursor"
        const val AUTO = "sync.auto"
    }
}
