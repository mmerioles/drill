package io.github.mmerioles.drill.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.core.Copy
import io.github.mmerioles.drill.core.Day
import io.github.mmerioles.drill.core.Heatmap
import io.github.mmerioles.drill.ink.Doodle
import io.github.mmerioles.drill.ink.LocalPalette
import android.text.format.DateFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle as DateStyle
import java.util.Locale
import kotlin.math.floor

// The year heatmap: as many trailing weeks as fit at square cells of 11–14
// with a 2 gap, the whole year on a tablet; tap a day for its time.

private val GAP = 2.dp
private val CELL_MIN = 11.dp
private val CELL_MAX = 14.dp
/** Room at the edges for today's outline, which sits outside its cell. */
private val OUTLINE_PAD = 1.75.dp
private val OUTLINE = 1.5.dp
private val MARGIN = OUTLINE_PAD + OUTLINE / 2
private val INK = listOf(0f, 0.16f, 0.36f, 0.62f, 0.92f)

@Composable
fun YearView(model: AppModel, filter: String?, setFilter: (String?) -> Unit, pickedDate: LocalDate?, pick: (LocalDate?) -> Unit) {
    val ink = LocalPalette.current
    val tags = model.recentTags
    if (filter != null && filter !in tags) setFilter(null)

    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        // Weeks that fit at the smallest cell; a full year may leave the grid
        // narrower than the column, and the rows above and below follow it.
        val room = maxWidth - MARGIN * 2
        val weeks = minOf(Heatmap.MAX_WEEKS, floor((room + GAP) / (CELL_MIN + GAP)).toInt()).coerceAtLeast(1)
        val cell = ((room - GAP * (weeks - 1)) / weeks).coerceAtMost(CELL_MAX)
        val pitchDp = cell + GAP
        val gridWidth = if (weeks == Heatmap.MAX_WEEKS) cell * weeks + GAP * (weeks - 1) + MARGIN * 2 else maxWidth

        Column(Modifier.width(gridWidth)) {
            Row(Modifier.fillMaxWidth().height(24.dp), verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.weight(1f))
                Row(Modifier.horizontalScroll(rememberScrollState()).selectableGroup(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Link("all", on = filter == null, selectable = true, compact = true, height = 24.dp) { setFilter(null) }
                    tags.forEach { t -> Link(t, on = filter == t, selectable = true, compact = true, height = 24.dp) { setFilter(t) } }
                }
            }
            Spacer(Modifier.height(12.dp))

            // The model's day, so the grid moves on at midnight.
            val today = model.today
            val all = model.sessions
            val heat = remember(all, filter, weeks, today) {
                Heatmap.build(all.filter { filter == null || it.tag == filter }, weeks, today)
            }
            val picked = heat.weeks.firstNotNullOfOrNull { w -> w.firstOrNull { it?.date == pickedDate } }
            val summary = "your year. today ${Copy.amount(heat.today)}, this week ${Copy.amount(heat.thisWeek)}, " +
                "streak ${Copy.days(heat.streak)}"
            val measurer = rememberTextMeasurer()
            val monthStyle = TextStyle(color = ink.faint, fontSize = 12.sp)
            val monthRow = with(LocalDensity.current) { measurer.measure("jan", monthStyle).size.height.toDp() } + 6.dp
            val height = monthRow + pitchDp * 7 - GAP + MARGIN

            Canvas(
                Modifier
                    .fillMaxWidth()
                    .height(height)
                    .semantics { contentDescription = summary }
                    .pointerInput(heat, pickedDate) {
                        detectTapGestures { at ->
                            val pitch = pitchDp.toPx()
                            val w = floor((at.x - MARGIN.toPx()) / pitch).toInt()
                            val d = floor((at.y - monthRow.toPx()) / pitch).toInt()
                            val day = heat.weeks.getOrNull(w)?.getOrNull(d)
                            pick(if (day == null || day.date == pickedDate) null else day.date)
                        }
                    },
            ) {
                val margin = MARGIN.toPx()
                val pitch = pitchDp.toPx()
                val side = cell.toPx()
                val top = monthRow.toPx()
                var lastMonth = -1
                heat.weeks.forEachIndexed { w, week ->
                    week.firstOrNull { it != null }?.let { first ->
                        val month = first.date.monthValue
                        // Skip a month that's only partly shown at the left edge.
                        if (month != lastMonth) {
                            if (lastMonth != -1 || first.date.dayOfMonth <= 7) {
                                val label = first.date.month.getDisplayName(DateStyle.SHORT, Locale.getDefault()).lowercase()
                                val text = measurer.measure(label, monthStyle, softWrap = false)
                                // A month just starting at the right edge waits for room.
                                if (margin + w * pitch + text.size.width <= size.width) drawText(text, topLeft = Offset(margin + w * pitch, 0f))
                            }
                            lastMonth = month
                        }
                    }
                    week.forEachIndexed { d, day ->
                        if (day == null) return@forEachIndexed
                        val x = margin + w * pitch
                        val y = top + d * pitch
                        val color = if (day.level > 0) ink.accent.copy(alpha = INK[day.level]) else ink.wash
                        drawPath(Doodle.square(x, y, side, ((w * 7 + d) * 31 + 7).toLong(), side / 12 * 0.35f), color)
                        val outline = when (day.date) {
                            picked?.date -> ink.faint
                            today -> ink.ink
                            else -> null
                        }
                        if (outline != null) {
                            val pad = OUTLINE_PAD.toPx()
                            drawRoundRect(
                                outline, Offset(x - pad, y - pad), Size(side + pad * 2, side + pad * 2),
                                CornerRadius(3.dp.toPx()), style = Stroke(OUTLINE.toPx()),
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
            Caption(heat, picked, legend = gridWidth >= 600.dp)
        }
    }
}

/** "wed, oct 7" in english, and the locale's own order elsewhere. */
private fun dayFormat(): DateTimeFormatter {
    val locale = Locale.getDefault()
    return DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "EEEMMMd"), locale)
}

/** The stats row, or the picked day's line; the legend only on a wide grid. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Caption(heat: Heatmap, picked: Day?, legend: Boolean) {
    val ink = LocalPalette.current
    if (picked != null) {
        Row(Modifier.heightIn(min = 24.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Words(dayFormat().format(picked.date).lowercase(), weight = FontWeight.SemiBold)
            Words("— " + if (picked.seconds > 0) Copy.amount(picked.seconds) else "nothing logged.", color = ink.faint)
        }
        return
    }
    FlowRow(
        Modifier.fillMaxWidth().heightIn(min = 24.dp),
        horizontalArrangement = Arrangement.spacedBy(24.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Stat("today", Copy.amount(heat.today))
        Stat("this week", Copy.amount(heat.thisWeek))
        Stat("streak", Copy.days(heat.streak))
        if (legend) {
            Spacer(Modifier.weight(1f))
            Row(
                Modifier.align(Alignment.CenterVertically).clearAndSetSemantics {},
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Words("less", size = 12.sp, color = ink.faint)
                INK.forEachIndexed { i, a ->
                    val color = if (i == 0) ink.wash else ink.accent.copy(alpha = a)
                    Spacer(Modifier.size(10.dp).background(color, RoundedCornerShape(2.dp)))
                }
                Words("more", size = 12.sp, color = ink.faint)
            }
        }
    }
}

@Composable
private fun Stat(label: String, value: String) {
    val ink = LocalPalette.current
    Row(Modifier.height(24.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Words(label, color = ink.faint)
        Words(value, weight = FontWeight.SemiBold)
    }
}
