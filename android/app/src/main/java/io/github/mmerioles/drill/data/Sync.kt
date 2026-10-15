package io.github.mmerioles.drill.data

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.mmerioles.drill.core.LocalStores
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The account and the sync loop (docs/SYNC.md): push what changed here, then
 * pull what changed elsewhere. Each account syncs its own store
 * ([LocalStores]); signing in never uploads what was written elsewhere.
 */
class Sync(
    private val app: Context,
    private val prefs: SharedPreferences,
    private val scope: CoroutineScope,
    /** The store in use now. */
    private val store: () -> SessionStore,
    /** Makes the given store the one in use and reloads; returns the one it replaced. */
    private val swap: suspend (SessionStore) -> SessionStore,
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

    /** Chose offline, or signed in, since the last sign-out. */
    var welcomed by mutableStateOf(prefs.getBoolean(Keys.WELCOMED, false))
        private set

    private val api = SupabaseApi.hosted
    private var running: Job? = null
    private var flushing: Job? = null
    /** Deleting the last account's store; the next sign-in waits for it. */
    private var retiring: Job? = null
    private var lastStarted = 0L

    val isSignedIn get() = account != null
    /** The welcome screen, instead of the timer. */
    val welcome get() = LocalStores.showWelcome(isSignedIn, welcomed)
    private val ephemeral get() = prefs.getBoolean(Keys.EPHEMERAL, false)

    fun continueOffline() {
        welcomed = true
        prefs.edit().putBoolean(Keys.WELCOMED, true).apply()
    }

    init {
        scope.launch { recount() }
    }

    fun updateAuto(on: Boolean) {
        auto = on
        prefs.edit().putBoolean(Keys.AUTO, on).apply()
        if (on) syncNow()
    }

    suspend fun recount() {
        withContext(Dispatchers.IO) { runCatching { store().unpushed() } }.onSuccess { unpushed = it }
    }

    fun autoSync() {
        if (auto) syncNow()
    }

    // Each returns null, or a sentence to show.

    /** An existing account: its own store, pulled from the start; offline stays as it is. */
    suspend fun signIn(username: String, password: String, stay: Boolean): String? = problem {
        begin(attempt { api.signIn(username, password) }, stay, bringOffline = false)
    }

    /** A new account takes the sessions made offline with it. */
    suspend fun createAccount(username: String, password: String, stay: Boolean): String? = problem {
        begin(attempt { api.createAccount(username, password) }, stay, bringOffline = true)
    }

    /** Null when the server couldn't be asked. */
    suspend fun usernameAvailable(name: String): Boolean? = try {
        withContext(Dispatchers.IO) { api.usernameAvailable(name) }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    private suspend fun begin(account: Account, stay: Boolean, bringOffline: Boolean) {
        retiring?.join()
        val mine = SessionStore(app, LocalStores.fileName(account.userID))
        val offline = swap(mine)
        withContext(Dispatchers.IO) {
            if (bringOffline) LocalStores.handOver(offline, mine)
            offline.close()
        }
        prefs.edit()
            .putString(Keys.cursor(account.userID), "0")
            .putBoolean(Keys.EPHEMERAL, !stay)
            .apply()
        save(account)
        state = State.Idle
        if (bringOffline) onPulled()
        recount()
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

    /**
     * Pushes what's left (for up to ten seconds), then forgets the account and
     * its store. False, having changed nothing, when sessions couldn't be
     * pushed; [anyway] signs out regardless.
     */
    suspend fun signOut(anyway: Boolean = false): Boolean {
        val account = account ?: return true
        if (!anyway && !flush(account, store())) return false
        if (this.account?.userID != account.userID) return true
        leave(account)
        return true
    }

    /** "stay signed in" was off: at a fresh launch or on the way out, push what's left and sign out. */
    fun endEphemeral() {
        val account = account ?: return
        if (!ephemeral) return
        val store = store()
        leave(account) { flush(account, store) }
    }

    /** True when nothing is left to push. */
    private suspend fun flush(account: Account, store: SessionStore): Boolean {
        val wait = running
        val job = scope.async(Dispatchers.IO) {
            wait?.join()
            if (store.unpushed() == 0) return@async true
            val token = fresh(account, force = false)
            store.dirty().chunked(200).forEach { batch ->
                ensureActive()
                api.push(batch, token)
                store.pushed(batch)
            }
            store.unpushed() == 0
        }
        flushing = job
        return withTimeoutOrNull(10_000L) { runCatching { job.await() }.getOrDefault(false) } ?: false
    }

    /**
     * Signed out at once, on the offline store; then, behind the scenes,
     * [first], revoke the token, and delete the account's store. The account
     * stays saved until that's done, so a launch mid-way finishes the job.
     */
    private fun leave(account: Account, revoke: Boolean = true, keepUnpushed: Boolean = false, first: suspend () -> Unit = {}) {
        val jobs = listOfNotNull(running, flushing)
        jobs.forEach { it.cancel() }
        running = null
        flushing = null
        this.account = null
        state = State.SignedOut
        unpushed = 0
        welcomed = false
        prefs.edit().putBoolean(Keys.WELCOMED, false).apply()
        val offline = SessionStore(app, LocalStores.fileName(null))
        retiring = scope.launch {
            val old = swap(offline)
            jobs.joinAll()
            first()
            withContext(Dispatchers.IO) {
                // A token the server turned down can't push; keep what it couldn't on the phone.
                if (keepUnpushed) offline.save(old.dirty(), local = true)
                if (revoke) api.signOut(account)
                old.close()
                app.deleteDatabase(old.databaseName)
            }
            if (this@Sync.account == null) save(null)
            prefs.edit().remove(Keys.cursor(account.userID)).remove(Keys.EPHEMERAL).apply()
            recount()
        }
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
        val store = store()
        try {
            val pulled = withContext(Dispatchers.IO) {
                // Tokens last an hour: swap one that's nearly out, and once
                // more if the server turns it down anyway.
                token = fresh(start, force = false)
                try {
                    exchange(token, store, start.userID)
                } catch (e: SupabaseApi.SignedOut) {
                    token = fresh(start, force = true)
                    exchange(token, store, start.userID)
                }
            }
            if (pulled) onPulled()
            if (account?.token != token) return // signed out meanwhile
            state = State.Idle
        } catch (e: SupabaseApi.SignedOut) {
            if (account?.userID != start.userID) return
            leave(start, revoke = false, keepUnpushed = true)
            return
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // A bad page, an unparseable date, the disk: call it offline and retry next time.
            if (account?.userID == start.userID) state = State.Offline
        }
        recount()
    }

    private suspend fun fresh(start: Account, force: Boolean): String {
        val current = account ?: start
        val fresh = api.refreshed(current, force)
        if (fresh != current) withContext(Dispatchers.Main) { if (account?.userID == start.userID) save(fresh) }
        return fresh.token
    }

    /** Returns true when the pull brought anything down. */
    private fun CoroutineScope.exchange(token: String, store: SessionStore, userID: String): Boolean {
        store.dirty().chunked(200).forEach { batch ->
            ensureActive()
            api.push(batch, token)
            store.pushed(batch)
        }
        var pulled = false
        do {
            ensureActive()
            val page = api.pull(prefs.getString(Keys.cursor(userID), "0")!!, token)
            ensureActive()
            if (store.save(page.sessions, local = false) > 0) pulled = true
            prefs.edit().putString(Keys.cursor(userID), page.cursor).apply()
        } while (page.more)
        return pulled
    }

    private fun loadAccount(): Account? = storedAccount(prefs)

    private fun save(account: Account?) {
        this.account = account
        prefs.edit().apply {
            if (account == null) {
                remove(Keys.USERNAME); remove(Keys.USER_ID); remove(Keys.TOKEN); remove(Keys.REFRESH); remove(Keys.EXPIRES)
            } else {
                putString(Keys.USERNAME, account.username)
                putString(Keys.USER_ID, account.userID)
                putString(Keys.TOKEN, account.token)
                putString(Keys.REFRESH, account.refreshToken)
                putLong(Keys.EXPIRES, account.expiresAt)
            }
        }.apply()
    }

    companion object {
        /**
         * The store to open at launch: the stored account's, or offline. The
         * first launch of this build hands an account the file it was using.
         */
        fun launchStore(context: Context, prefs: SharedPreferences): String {
            val userID = storedAccount(prefs)?.userID
            if (!prefs.getBoolean(Keys.SPLIT, false)) {
                val dir = context.getDatabasePath(LocalStores.OFFLINE).parentFile!!
                if (LocalStores.upgrade(done = false, dir, userID)) {
                    prefs.edit().apply {
                        putBoolean(Keys.SPLIT, true)
                        if (userID != null) {
                            putString(Keys.USER_ID, userID)
                            prefs.getString(Keys.CURSOR, null)?.let { putString(Keys.cursor(userID), it) }
                        }
                        remove(Keys.CURSOR)
                    }.commit()
                }
            }
            return LocalStores.fileName(userID)
        }

        private fun storedAccount(prefs: SharedPreferences): Account? {
            val username = prefs.getString(Keys.USERNAME, null) ?: return null
            val token = prefs.getString(Keys.TOKEN, null) ?: return null
            val refresh = prefs.getString(Keys.REFRESH, null) ?: return null
            val userID = prefs.getString(Keys.USER_ID, null) ?: LocalStores.subject(token) ?: return null
            return Account(username, userID, token, refresh, prefs.getLong(Keys.EXPIRES, 0L))
        }
    }

    private object Keys {
        const val USERNAME = "sync.username"
        const val USER_ID = "sync.userID"
        const val TOKEN = "sync.token"
        const val REFRESH = "sync.refreshToken"
        const val EXPIRES = "sync.expiresAt" // epoch millis
        /** Before stores were split: the one cursor. */
        const val CURSOR = "sync.cursor"
        fun cursor(userID: String) = "sync.cursor.$userID"
        const val AUTO = "sync.auto"
        const val EPHEMERAL = "sync.ephemeral"
        const val SPLIT = "sync.split"
        const val WELCOMED = "drill.welcomed"
    }
}
