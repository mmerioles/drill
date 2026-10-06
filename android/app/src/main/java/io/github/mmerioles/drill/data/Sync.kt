package io.github.mmerioles.drill.data

import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException

/**
 * Your account and the sync loop (docs/SYNC.md, "Client loop"), like
 * Sync.swift: push what changed here, then pull what changed elsewhere.
 * Runs at launch, after each logged block, every minute while the app is
 * open, and when you press sync.
 */
class Sync(
    private val store: SessionStore,
    private val deviceID: String,
    private val prefs: SharedPreferences,
    private val scope: CoroutineScope,
    private val onPulled: () -> Unit,
) {
    enum class State { SignedOut, Idle, Syncing, Offline, Unconfirmed }

    var account by mutableStateOf(loadAccount())
        private set
    var state by mutableStateOf(if (account == null) State.SignedOut else State.Idle)
        private set
    /** True for a moment after a sync lands, for a quiet "synced". */
    var justSynced by mutableStateOf(false)
        private set
    /** A self-hosted server from settings, or null for ours. */
    var customServer by mutableStateOf(prefs.getString(Keys.SERVER, null))
        private set

    private var running: Job? = null

    val isSignedIn get() = account != null

    /** The self-hosted server from settings, or ours on Supabase. */
    val backend: SyncBackend get() = customServer?.let(::SyncApi) ?: SupabaseApi.hosted

    /** Points sync at a self-hosted server, or back at ours when empty. Only
     *  while signed out: a token only works where it was made. Returns a
     *  sentence to show when it can't. */
    fun setServer(text: String): String? {
        if (isSignedIn) return "sign out to change servers."
        if (text.isBlank()) {
            customServer = null
            prefs.edit().remove(Keys.SERVER).apply()
            return null
        }
        val url = SyncApi.serverUrl(text) ?: return "that address doesn't look right."
        customServer = url
        prefs.edit().putString(Keys.SERVER, url).apply()
        return null
    }

    /** An account made here whose email link hasn't been clicked yet, as
     *  the sheet and settings show it. [confirmed] turns true for a moment
     *  once the link is clicked, for the check mark. */
    data class Waiting(val email: String, val confirmed: Boolean = false)

    var waiting by mutableStateOf<Waiting?>(null)
        private set

    /** What signing in by itself needs. Memory only, password and all, just
     *  long enough to sign in once the link is clicked. A null [userID]
     *  means signing in found the email unconfirmed: then the only way to
     *  tell is to try signing in again, less often. */
    private class Pending(val email: String, val password: String, val userID: String?)

    private var watching: Job? = null

    // Each returns null, or a sentence to show.

    suspend fun signIn(email: String, password: String): String? = problem {
        stopWaiting()
        val to = email.trim()
        try {
            begin(attempt { backend.signIn(to, password) })
        } catch (e: SyncBackend.Unconfirmed) {
            watch(Pending(to, password, null))
        }
    }

    /** Makes the account, then signs in, or waits for the email link. */
    suspend fun createAccount(email: String, password: String): String? = problem {
        stopWaiting()
        val to = email.trim()
        when (val made = attempt { backend.createAccount(to, password) }) {
            is SignUp.SignedIn -> begin(made.account)
            is SignUp.ConfirmByLink -> watch(Pending(to, password, made.userID))
        }
    }

    suspend fun resendLink(): String? = problem {
        val email = waiting?.email ?: return@problem
        attempt { backend.resendLink(email) }
    }

    /** Gives up waiting, for a wrong email or a change of mind. */
    fun stopWaiting() {
        watching?.cancel()
        watching = null
        waiting = null
    }

    /** Checks every few seconds whether the link was clicked, then signs in. */
    private fun watch(pending: Pending) {
        watching?.cancel()
        waiting = Waiting(pending.email)
        val backend = backend
        val began = System.currentTimeMillis()
        watching = scope.launch {
            while (isActive) {
                // Quick at first, while they're likely at their inbox.
                val quick = System.currentTimeMillis() - began < 30 * 60_000L
                delay(if (pending.userID == null) 10_000L else if (quick) 3_000L else 30_000L)
                try {
                    val account = withContext(Dispatchers.IO) {
                        if (pending.userID != null && !backend.isConfirmed(pending.userID)) null
                        else backend.signIn(pending.email, pending.password)
                    } ?: continue
                    confirmed(account)
                    return@launch
                } catch (e: CancellationException) {
                    throw e
                } catch (e: SyncBackend.Rejected) {
                    waiting = null // the password changed elsewhere: sign in by hand
                    return@launch
                } catch (e: Exception) {
                    // not yet, or offline for a moment
                }
            }
        }
    }

    private suspend fun confirmed(account: Account) {
        if (waiting == null) return
        waiting = waiting?.copy(confirmed = true)
        begin(account)
        delay(2500)
        if (waiting?.confirmed == true) waiting = null
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

    /** Runs a call off the main thread, turning failures into [Problem]s.
     *  [SyncBackend.Unconfirmed] passes through for the caller. */
    private suspend fun <T> attempt(call: () -> T): T = try {
        withContext(Dispatchers.IO) { call() }
    } catch (e: CancellationException) {
        throw e
    } catch (e: SyncBackend.Unconfirmed) {
        throw e
    } catch (e: SyncBackend.Rejected) {
        throw Problem(e.message ?: "something went wrong. try again.")
    } catch (e: Exception) {
        throw Problem("can't connect. try again in a bit.")
    }

    private suspend fun problem(work: suspend () -> Unit): String? = try {
        work()
        null
    } catch (e: Problem) {
        e.message
    } catch (e: SyncBackend.Unconfirmed) {
        "confirm your email first."
    }

    fun signOut() {
        stopWaiting()
        val account = account
        val backend = backend
        if (account != null) {
            scope.launch(Dispatchers.IO) { backend.signOut(account) }
        }
        running?.cancel()
        running = null
        save(null)
        state = State.SignedOut
    }

    /** Starts a sync unless one is already running. */
    fun syncNow() {
        val account = account ?: return
        if (running?.isActive == true) return
        val backend = backend
        running = scope.launch { run(backend, account) }
    }

    private suspend fun run(api: SyncBackend, start: Account) {
        state = State.Syncing
        var token = start.token
        try {
            val pulled = withContext(Dispatchers.IO) {
                // Hosted tokens last an hour: swap one that's nearly out, and
                // once more if the server turns it down anyway.
                token = fresh(api, start, force = false)
                try {
                    exchange(api, token)
                } catch (e: SyncBackend.SignedOut) {
                    if (start.refreshToken == null) throw e
                    token = fresh(api, start, force = true)
                    exchange(api, token)
                }
            }
            if (pulled) onPulled()
            if (account?.token != token) return // signed out meanwhile
            state = State.Idle
            justSynced = true
            delay(2000)
            justSynced = false
        } catch (e: SyncBackend.SignedOut) {
            if (account?.email != start.email) return
            save(null)
            state = State.SignedOut
        } catch (e: SyncBackend.Unconfirmed) {
            state = State.Unconfirmed
        } catch (e: IOException) {
            if (account?.email == start.email) state = State.Offline
        } catch (e: SyncBackend.Rejected) {
            if (account?.email == start.email) state = State.Offline
        } catch (e: org.json.JSONException) {
            if (account?.email == start.email) state = State.Offline
        }
    }

    /** A token good for a while, saved for next time. */
    private suspend fun fresh(api: SyncBackend, start: Account, force: Boolean): String {
        val current = account ?: start
        val fresh = api.refreshed(current, force)
        if (fresh != current) withContext(Dispatchers.Main) { if (account?.email == start.email) save(fresh) }
        return fresh.token
    }

    /** Push what changed here, then pull what changed elsewhere. True when
     *  something came down. */
    private fun exchange(api: SyncBackend, token: String): Boolean {
        store.dirty().chunked(200).forEach { batch ->
            api.push(batch, deviceID, token)
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
        val email = prefs.getString(Keys.EMAIL, null) ?: return null
        val token = prefs.getString(Keys.TOKEN, null) ?: return null
        return Account(
            email, token, prefs.getBoolean(Keys.CONFIRMED, false),
            refreshToken = prefs.getString(Keys.REFRESH, null),
            expiresAt = prefs.getLong(Keys.EXPIRES, 0L).takeIf { it > 0 },
        )
    }

    private fun save(account: Account?) {
        this.account = account
        prefs.edit().apply {
            if (account == null) {
                remove(Keys.EMAIL); remove(Keys.TOKEN); remove(Keys.CONFIRMED)
                remove(Keys.REFRESH); remove(Keys.EXPIRES)
            } else {
                putString(Keys.EMAIL, account.email)
                putString(Keys.TOKEN, account.token)
                putBoolean(Keys.CONFIRMED, account.confirmed)
                putString(Keys.REFRESH, account.refreshToken)
                putLong(Keys.EXPIRES, account.expiresAt ?: 0L)
            }
        }.apply()
    }

    private object Keys {
        const val EMAIL = "sync.email"
        const val TOKEN = "sync.token"
        const val CONFIRMED = "sync.confirmed"
        const val REFRESH = "sync.refreshToken" // hosted only
        const val EXPIRES = "sync.expiresAt" // hosted only, epoch millis
        const val SERVER = "sync.server" // self-hosted only
        const val CURSOR = "sync.cursor"
    }
}
