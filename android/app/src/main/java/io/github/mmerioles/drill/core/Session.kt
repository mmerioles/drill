package io.github.mmerioles.drill.core

import java.time.Instant
import java.time.OffsetDateTime
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * One block of focused time, the only record drill keeps. The same row
 * as FocusSession.swift and the web app's sessions (docs/SYNC.md): rows are
 * never hard-deleted, and two copies merge by newer [updatedAt] wins.
 * Times are epoch ms.
 */
data class FocusSession(
    val id: String,
    val startedAt: Long,
    val endedAt: Long,
    /** Time actually spent focusing; excludes pauses. */
    val focusSeconds: Double,
    val plannedSeconds: Double,
    /** False when the block was cut short by skip or reset. */
    val completed: Boolean,
    val tag: String?,
    val deviceID: String,
    val updatedAt: Long,
    /** Tombstone. Non-null rows are hidden here but still synced. */
    val deletedAt: Long? = null,
) {
    companion object {
        /** A row for a block from the engine. The id comes from the device and
         *  start time, so logging the same block twice writes one row. */
        fun from(record: FocusRecord, tag: String?, deviceID: String, now: Long) = FocusSession(
            id = UUID.nameUUIDFromBytes("$deviceID:${record.startedAt}".toByteArray())
                .toString().uppercase(),
            startedAt = record.startedAt,
            endedAt = record.endedAt,
            focusSeconds = Math.round(record.focusSeconds).toDouble(),
            plannedSeconds = record.plannedSeconds.toDouble(),
            completed = record.completed,
            tag = tag,
            deviceID = deviceID,
            updatedAt = now,
        )
    }
}

/** The wire format's dates: ISO-8601 UTC in whole seconds. */
object WireDate {
    fun format(ms: Long): String = Instant.ofEpochMilli(ms).truncatedTo(ChronoUnit.SECONDS).toString()
    fun parse(text: String): Long = OffsetDateTime.parse(text).toInstant().toEpochMilli()
}
