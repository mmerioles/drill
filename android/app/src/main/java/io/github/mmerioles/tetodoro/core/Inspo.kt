package io.github.mmerioles.tetodoro.core

import java.time.LocalDate

// Shuzo Matsuoka's short cheer-up videos: the "〜あなたに" messages from his
// official YouTube channel, with the clams clip first. The list lives in
// Support/inspo.json (see scripts/make-inspo.sh, which writes InspoVideos.kt).
// The shuffle is kept in step with web/static/inspo.js and Inspo.swift, so
// every device shows the same few videos on the same day.

object Inspo {
    data class Video(
        val number: Int,
        val youtube: String,
        /** In the daily rotation. The rest are sponsor and travel skits. */
        val daily: Boolean,
        val title: String,
        val japanese: String,
    ) {
        val url get() = "https://www.youtube.com/watch?v=$youtube"
    }

    const val PER_DAY = 5

    val videos: List<Video> get() = INSPO_VIDEOS

    /** A day as a number, like 20260928: the key for watched videos and the seed. */
    fun day(date: LocalDate = LocalDate.now()) = date.year * 10000 + date.monthValue * 100 + date.dayOfMonth

    /**
     * A fresh handful each day, seeded by the date, leaving out anything
     * watched before today. Cheer-up messages come first, the skits once those
     * run out, and the full rotation again once you've seen everything.
     */
    fun today(seen: Set<String>, on: Int = day()): List<Video> {
        val next = mulberry32(on)
        val daily = shuffled(videos.filter { it.daily }, next)
        val rest = shuffled(videos.filter { !it.daily }, next)
        val fresh = (daily + rest).filter { it.youtube !in seen }
        return fresh.ifEmpty { daily }.take(PER_DAY)
    }

    private fun shuffled(videos: List<Video>, next: () -> UInt): List<Video> {
        val pool = videos.toMutableList()
        for (i in pool.size - 1 downTo 1) {
            val j = (next() % (i + 1).toUInt()).toInt()
            pool[i] = pool[j].also { pool[j] = pool[i] }
        }
        return pool
    }

    /** A tiny seeded generator, bit-for-bit the same as the JS and Swift ones. */
    internal fun mulberry32(seed: Int): () -> UInt {
        var a = seed.toUInt()
        return {
            a += 0x6D2B79F5u
            var t = a
            t = (t xor (t shr 15)) * (t or 1u)
            t = t xor (t + (t xor (t shr 7)) * (t or 61u))
            t xor (t shr 14)
        }
    }
}
