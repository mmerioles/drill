package io.github.mmerioles.drill.data

import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
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
    val server: String? get() = customServer ?: DEFAULT_SERVER

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
        val url = SyncApi.serverUrl(text) ?: return "that server address doesn't look right."
        customServer = url
        prefs.edit().putString(Keys.SERVER, url).apply()
        return null
    }

    /** Signs in, or makes the account first. Everything already on this
     *  phone joins the account. Returns a sentence to show on failure. */
    suspend fun signIn(email: String, password: String, create: Boolean): String? {
        val server = server ?: return "sync isn't open yet. to self-host, add your server in settings."
        val account = try {
            withContext(Dispatchers.IO) { SyncApi(server).signIn(email.trim(), password, create) }
        } catch (e: SyncApi.Rejected) {
            return e.message
        } catch (e: Exception) {
            return "can't reach the server. try again in a bit."
        }
        save(account)
        withContext(Dispatchers.IO) { store.markAllDirty() }
        prefs.edit().putString(Keys.CURSOR, "0").apply()
        state = State.Idle
        syncNow()
        return null
    }

    fun signOut() {
        val token = account?.token
        val server = server
        if (token != null && server != null) {
            scope.launch(Dispatchers.IO) { SyncApi(server).signOut(token) }
        }
        running?.cancel()
        running = null
        save(null)
        state = State.SignedOut
    }

    /** Starts a sync unless one is already running. */
    fun syncNow() {
        val account = account ?: return
        val server = server ?: return
        if (running?.isActive == true) return
        running = scope.launch { run(SyncApi(server), account.token) }
    }

    private suspend fun run(api: SyncApi, token: String) {
        state = State.Syncing
        try {
            val pulled = withContext(Dispatchers.IO) {
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
                pulled
            }
            if (pulled) onPulled()
            if (account?.token != token) return // signed out meanwhile
            state = State.Idle
            justSynced = true
            delay(2000)
            justSynced = false
        } catch (e: SyncApi.SignedOut) {
            save(null)
            state = State.SignedOut
        } catch (e: SyncApi.Unconfirmed) {
            state = State.Unconfirmed
        } catch (e: IOException) {
            if (account?.token == token) state = State.Offline
        } catch (e: SyncApi.Rejected) {
            if (account?.token == token) state = State.Offline
        } catch (e: org.json.JSONException) {
            if (account?.token == token) state = State.Offline
        }
    }

    private fun loadAccount(): SyncApi.Account? {
        val email = prefs.getString(Keys.EMAIL, null) ?: return null
        val token = prefs.getString(Keys.TOKEN, null) ?: return null
        return SyncApi.Account(email, token, prefs.getBoolean(Keys.CONFIRMED, false))
    }

    private fun save(account: SyncApi.Account?) {
        this.account = account
        prefs.edit().apply {
            if (account == null) {
                remove(Keys.EMAIL); remove(Keys.TOKEN); remove(Keys.CONFIRMED)
            } else {
                putString(Keys.EMAIL, account.email)
                putString(Keys.TOKEN, account.token)
                putBoolean(Keys.CONFIRMED, account.confirmed)
            }
        }.apply()
    }

    private object Keys {
        const val EMAIL = "sync.email"
        const val TOKEN = "sync.token"
        const val CONFIRMED = "sync.confirmed"
        const val SERVER = "sync.server" // self-hosted only
        const val CURSOR = "sync.cursor"
    }

    companion object {
        /** Where accounts live unless settings name a self-hosted server. Null
         *  until ours is up, like Sync.defaultServer on the mac. */
        val DEFAULT_SERVER: String? = null
    }
}
