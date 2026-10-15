package io.github.mmerioles.drill.core

import java.io.File
import java.util.Base64

/** A store's rows, as the tests see them. */
interface SessionRows {
    /** Every row, tombstones too. */
    fun all(): List<FocusSession>
    fun dirty(): List<FocusSession>
    fun save(rows: List<FocusSession>, local: Boolean): Int
}

/**
 * Sessions belong to one account. Each account has its own store, keyed by
 * its Supabase user id, and nothing ever crosses between them. Signed out,
 * nothing is kept (an in-memory store); the old offline file is left as it is.
 */
object LocalStores {
    /** Before accounts were required: the store used while signed out. Never opened now. */
    const val OFFLINE = "drill.sqlite"

    /** Null: in memory. */
    fun fileName(userID: String?) = userID?.let { "drill-$it.sqlite" }

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
