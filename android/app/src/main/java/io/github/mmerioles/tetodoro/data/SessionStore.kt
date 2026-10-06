package io.github.mmerioles.tetodoro.data

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import io.github.mmerioles.tetodoro.core.FocusSession

/**
 * Sessions in SQLite, merged by docs/SYNC.md's one rule: for each id, the
 * row with the newer updatedAt wins. Rows written on this phone are marked
 * dirty until a push carries them to the server.
 */
class SessionStore(context: Context) :
    SQLiteOpenHelper(context, "tetodoro.sqlite", null, 1) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                startedAt INTEGER NOT NULL,
                endedAt INTEGER NOT NULL,
                focusSeconds REAL NOT NULL,
                plannedSeconds REAL NOT NULL,
                completed INTEGER NOT NULL,
                tag TEXT,
                deviceID TEXT NOT NULL,
                updatedAt INTEGER NOT NULL,
                deletedAt INTEGER,
                dirty INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        db.execSQL("CREATE INDEX sessions_dirty ON sessions (dirty)")
    }

    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) = Unit

    /** Saves rows that win the merge. Local rows always win and queue a push.
     *  Returns how many rows changed. */
    @Synchronized
    fun save(rows: List<FocusSession>, local: Boolean): Int {
        if (rows.isEmpty()) return 0
        val db = writableDatabase
        var changed = 0
        db.beginTransaction()
        try {
            for (row in rows) {
                if (!local) {
                    val mine = db.rawQuery("SELECT updatedAt FROM sessions WHERE id = ?", arrayOf(row.id))
                        .use { if (it.moveToFirst()) it.getLong(0) else null }
                    if (mine != null && mine >= row.updatedAt) continue
                }
                db.insertWithOnConflict("sessions", null, values(row, dirty = local), SQLiteDatabase.CONFLICT_REPLACE)
                changed++
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return changed
    }

    /** Live sessions, oldest first. */
    @Synchronized
    fun live(): List<FocusSession> =
        query("SELECT * FROM sessions WHERE deletedAt IS NULL ORDER BY startedAt", emptyArray())

    /** Rows waiting to be pushed. */
    @Synchronized
    fun dirty(): List<FocusSession> = query("SELECT * FROM sessions WHERE dirty = 1", emptyArray())

    /** Clears the push mark on rows the server took, unless they changed since. */
    @Synchronized
    fun pushed(rows: List<FocusSession>) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (row in rows) {
                db.execSQL(
                    "UPDATE sessions SET dirty = 0 WHERE id = ? AND updatedAt = ?",
                    arrayOf<Any>(row.id, row.updatedAt),
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** On sign-in, everything on this phone joins the account. */
    @Synchronized
    fun markAllDirty() {
        writableDatabase.execSQL("UPDATE sessions SET dirty = 1")
    }

    private fun query(sql: String, args: Array<String>): List<FocusSession> =
        readableDatabase.rawQuery(sql, args).use { c ->
            buildList { while (c.moveToNext()) add(row(c)) }
        }

    private fun row(c: Cursor) = FocusSession(
        id = c.getString(c.getColumnIndexOrThrow("id")),
        startedAt = c.getLong(c.getColumnIndexOrThrow("startedAt")),
        endedAt = c.getLong(c.getColumnIndexOrThrow("endedAt")),
        focusSeconds = c.getDouble(c.getColumnIndexOrThrow("focusSeconds")),
        plannedSeconds = c.getDouble(c.getColumnIndexOrThrow("plannedSeconds")),
        completed = c.getInt(c.getColumnIndexOrThrow("completed")) != 0,
        tag = c.getColumnIndexOrThrow("tag").let { if (c.isNull(it)) null else c.getString(it) },
        deviceID = c.getString(c.getColumnIndexOrThrow("deviceID")),
        updatedAt = c.getLong(c.getColumnIndexOrThrow("updatedAt")),
        deletedAt = c.getColumnIndexOrThrow("deletedAt").let { if (c.isNull(it)) null else c.getLong(it) },
    )

    private fun values(s: FocusSession, dirty: Boolean) = ContentValues().apply {
        put("id", s.id)
        put("startedAt", s.startedAt)
        put("endedAt", s.endedAt)
        put("focusSeconds", s.focusSeconds)
        put("plannedSeconds", s.plannedSeconds)
        put("completed", if (s.completed) 1 else 0)
        put("tag", s.tag)
        put("deviceID", s.deviceID)
        put("updatedAt", s.updatedAt)
        put("deletedAt", s.deletedAt)
        put("dirty", if (dirty) 1 else 0)
    }
}
