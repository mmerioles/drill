package io.github.mmerioles.tetodoro.ink

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sin

// tetodoro's ink look (Sources/InkKit, web/static/ink.js): paper, one ink,
// lots of air, lowercase words. Light is "teto", with her crimson for
// progress only; dark is pure monochrome.

@Immutable
data class Palette(val paper: Color, val ink: Color, val accent: Color, val dark: Boolean) {
    /** Secondary text and idle strokes. */
    val faint get() = ink.copy(alpha = 0.45f)
    /** Hairlines, empty cells, tracks. */
    val ghost get() = ink.copy(alpha = 0.12f)
    /** Empty heatmap days. */
    val wash get() = ink.copy(alpha = 0.055f)

    companion object {
        val light = Palette(Color(0xFFF2F0ED), Color(0xFF2B2A2F), Color(0xFFCF3A4F), dark = false)
        val dark = Palette(Color(0xFF121211), Color(0xFFF1F0EB), Color(0xFFF1F0EB), dark = true)
    }
}

val LocalPalette = staticCompositionLocalOf { Palette.light }

/** Hand-drawn strokes. Every stroke is jittered by a seeded wobble; stepping
 *  the seed every [BOIL_MS] gives the hand-drawn "boil". */
object Doodle {
    const val BOIL_MS = 400L

    private fun wobble(seed: Long): () -> Float {
        var s = seed
        return {
            s = s * 6364136223846793005L + 1442695040888963407L
            ((s ushr 33) % 1000).toFloat() / 1000f - 0.5f
        }
    }

    private fun jitter(pts: List<Offset>, seed: Long, amp: Float): List<Offset> {
        val next = wobble(seed)
        return pts.map { Offset(it.x + next() * amp * 2, it.y + next() * amp * 2) }
    }

    private fun mid(a: Offset, b: Offset) = Offset((a.x + b.x) / 2, (a.y + b.y) / 2)

    /** A soft curve through pts. */
    fun curve(pts: List<Offset>, closed: Boolean): Path {
        val p = Path()
        if (pts.size < 2) return p
        if (closed) {
            val n = pts.size
            val start = mid(pts[n - 1], pts[0])
            p.moveTo(start.x, start.y)
            for (i in 0 until n) {
                val m = mid(pts[i], pts[(i + 1) % n])
                p.quadraticTo(pts[i].x, pts[i].y, m.x, m.y)
            }
            p.close()
            return p
        }
        p.moveTo(pts[0].x, pts[0].y)
        for (i in 1 until pts.size) {
            val m = mid(pts[i - 1], pts[i])
            p.quadraticTo(pts[i - 1].x, pts[i - 1].y, m.x, m.y)
        }
        p.lineTo(pts.last().x, pts.last().y)
        return p
    }

    /** A square whose edges wobble but whose corners stay corners. */
    fun square(x: Float, y: Float, size: Float, seed: Long, amp: Float = 0.35f): Path {
        val c = listOf(Offset(x, y), Offset(x + size, y), Offset(x + size, y + size), Offset(x, y + size))
        val samples = buildList {
            c.forEachIndexed { i, a ->
                val b = c[(i + 1) % 4]
                for (t in 0 until 3) add(Offset(a.x + (b.x - a.x) * t / 3, a.y + (b.y - a.y) * t / 3))
            }
        }
        val pts = jitter(samples, seed, amp)
        return Path().apply {
            moveTo(pts[0].x, pts[0].y)
            pts.drop(1).forEach { lineTo(it.x, it.y) }
            close()
        }
    }

    class Ring(val track: Path, val arc: Path?, val tip: Offset?)

    /** The timer face: a dotted track and an inked arc from twelve o'clock. */
    fun ring(size: Float, progress: Float, tick: Long, lineWidth: Float): Ring {
        val c = size / 2
        val r = size / 2 - lineWidth * 2
        val samples = 72
        fun point(i: Int, n: Int, sweep: Double): Offset {
            val a = -PI / 2 + sweep * i / n
            return Offset((c + cos(a) * r).toFloat(), (c + sin(a) * r).toFloat())
        }
        val track = curve(jitter(List(samples) { point(it, samples, 2 * PI) }, tick + 3, size / 270 * 0.7f), true)
        val p = progress.coerceIn(0f, 1f)
        if (p <= 0.001f) return Ring(track, null, null)
        val n = max(2, floor(samples * p).toInt())
        val pts = jitter(List(n + 1) { point(it, n, 2 * PI * p) }, tick + 17, size / 270 * 0.9f)
        return Ring(track, curve(pts, false), pts.last())
    }

    /** Teto's drill curl: a tapering corkscrew. */
    fun drill(s: Float, tick: Long, roughness: Float = 1f): Path {
        val turns = 3.4
        val steps = 36
        val amp = s / 60 * roughness
        val next = wobble(tick + 5)
        val pts = List(steps + 1) { i ->
            val t = i.toFloat() / steps
            val angle = t * turns * 2 * PI
            val radius = s * (0.30f * (1 - t) + 0.04f)
            val y = s * (0.10f + 0.78f * t) + sin(angle).toFloat() * radius * 0.32f
            val a = amp * 0.6f * (1 - 0.7f * t) * 2
            Offset(s * 0.5f + cos(angle).toFloat() * radius + next() * a, y + next() * a)
        }
        return curve(pts, false)
    }
}
