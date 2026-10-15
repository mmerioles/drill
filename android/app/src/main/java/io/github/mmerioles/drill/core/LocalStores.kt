package io.github.mmerioles.drill.core

import java.io.File
import java.util.Base64

/** What moving sessions between stores needs from one. */
interface SessionRows {
    /** Every row, tombstones too. */
    fun all(): List<FocusSession>
    fun dirty(): List<FocusSession>
    fun save(rows: List<FocusSession>, local: Boolean): Int
    fun clear()
}

/**
 * Sessions belong to one account. The offline store is used only while
 * nobody is signed in; each signed-in account has its own, keyed by its
 * Supabase user id, and nothing crosses between them except when an account
 * is created from offline.
 */
object LocalStores {
    const val OFFLINE = "drill.sqlite"

    fun fileName(userID: String?) = if (userID == null) OFFLINE else "drill-$userID.sqlite"

    /** Create account: the offline rows join the new account, unpushed, and leave offline. */
    fun handOver(offline: SessionRows, account: SessionRows) {
        account.save(offline.all(), local = true)
        offline.clear()
    }

    /** At launch: nobody signed in and offline not chosen yet. */
    fun showWelcome(signedIn: Boolean, welcomed: Boolean) = !signedIn && !welcomed

    /**
     * Once, at the first launch of the build that split the stores: an
     * account's sessions were in the offline file, so that file (push marks
     * and all) becomes the account's. Returns whether it's done.
     */
    fun upgrade(done: Boolean, dir: File, userID: String?): Boolean {
        if (done) return true
        if (userID == null) return true
        val target = File(dir, fileName(userID))
        if (target.exists()) return true
        for (suffix in listOf("", "-journal", "-wal", "-shm")) {
            val from = File(dir, OFFLINE + suffix)
            if (from.exists() && !from.renameTo(File(dir, fileName(userID) + suffix))) return false
        }
        return true
    }

    /** The user id in an access token's `sub` claim, for accounts saved before ids were. */
    fun subject(token: String): String? = runCatching {
        val payload = String(Base64.getUrlDecoder().decode(token.split(".")[1].trimEnd('=')))
        Regex("\"sub\"\\s*:\\s*\"([^\"]+)\"").find(payload)?.groupValues?.get(1)
    }.getOrNull()
}
