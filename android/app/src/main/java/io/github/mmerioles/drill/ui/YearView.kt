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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
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
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.core.Day
import io.github.mmerioles.drill.core.Heatmap
import io.github.mmerioles.drill.ink.Doodle
import io.github.mmerioles.drill.ink.LocalPalette
import android.text.format.DateFormat
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle as DateStyle
import java.util.Locale
import kotlin.math.floor

// The year, as in HeatmapView.swift and the web app: the grid stretches to
// the width, a phone shows half a year, and a tapped day shows its time.

private const val GAP = 0.24f
/** Room at the grid's edges for today's outline: it sits 1.75dp out from
 *  its cell with a 1.5dp stroke, so the outline, not the cells, meets the
 *  content edges. */
private val OUTLINE_PAD = 1.75.dp
private val OUTLINE = 1.5.dp
private val MARGIN = OUTLINE_PAD + OUTLINE / 2
private val INK = listOf(0f, 0.16f, 0.36f, 0.62f, 0.92f)

@Composable
fun YearView(model: AppModel) {
    val ink = LocalPalette.current
    var filter by rememberSaveable { mutableStateOf<String?>(null) }
    var picked by remember { mutableStateOf<Day?>(null) }
    val tags = model.recentTags
    if (filter != null && filter !in tags) filter = null

    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Words("your year", Modifier.semantics { heading() }, size = 18.sp, weight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            // Compact, so the last one ends on the grid's right edge.
            Row(Modifier.horizontalScroll(rememberScrollState()).selectableGroup(), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Link("all", size = 13.sp, on = filter == null, selectable = true, compact = true) { filter = null }
                tags.forEach { t -> Link(t, size = 13.sp, on = filter == t, selectable = true, compact = true) { filter = t } }
            }
        }
        Spacer(Modifier.height(2.dp))

        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val weeks = if (maxWidth < 520.dp) 26 else Heatmap.MAX_WEEKS
            // The model's day, not the clock's: it moves on at midnight even
            // when nothing else changes.
            val today = model.today
            val all = model.sessions
            val heat = remember(all, filter, weeks, today) {
                Heatmap.build(all.filter { filter == null || it.tag == filter }, weeks, today)
            }
            val summary = "your year. today ${amount(heat.today)}, this week ${amount(heat.thisWeek)}, " +
                "streak ${streak(heat.streak)}"
            val measurer = rememberTextMeasurer()
            val monthStyle = TextStyle(color = ink.faint, fontSize = 10.sp)
            // Room for the month names, more when the words are large.
            val monthRow = with(LocalDensity.current) { maxOf(16.dp, monthStyle.fontSize.toDp() * 1.5f) }
            val pitchDp = (maxWidth - MARGIN * 2) / (weeks - GAP)
            val height = monthRow + pitchDp * 7 - pitchDp * GAP + MARGIN

            Canvas(
                Modifier
                    .fillMaxWidth()
                    .height(height)
                    .semantics { contentDescription = summary }
                    .pointerInput(heat) {
                        detectTapGestures { at ->
                            val margin = MARGIN.toPx()
                            val pitch = (size.width - margin * 2) / (weeks - GAP)
                            val w = floor((at.x - margin) / pitch).toInt()
                            val d = floor((at.y - monthRow.toPx()) / pitch).toInt()
                            val day = heat.weeks.getOrNull(w)?.getOrNull(d)
                            picked = if (day == null || day.date == picked?.date) null else day
                        }
                    },
            ) {
                val margin = MARGIN.toPx()
                val pitch = (size.width - margin * 2) / (weeks - GAP)
                val cell = pitch * (1 - GAP)
                val top = monthRow.toPx()
                var lastMonth = -1
                heat.weeks.forEachIndexed { w, week ->
                    week.firstOrNull { it != null }?.let { first ->
                        val month = first.date.monthValue
                        // Label a month at its first full column, not the half-column at the left edge.
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
                        drawPath(Doodle.square(x, y, cell, ((w * 7 + d) * 31 + 7).toLong(), cell / 12 * 0.35f), color)
                        val outline = when (day.date) {
                            picked?.date -> ink.faint
                            today -> ink.ink
                            else -> null
                        }
                        if (outline != null) {
                            val pad = OUTLINE_PAD.toPx()
                            drawRoundRect(
                                outline, Offset(x - pad, y - pad), Size(cell + pad * 2, cell + pad * 2),
                                CornerRadius(3.dp.toPx()), style = Stroke(OUTLINE.toPx()),
                            )
                        }
                    }
                }
            }
            Caption(heat, picked, Modifier.padding(top = height + 12.dp))
        }
    }
}

private fun streak(days: Int) = if (days == 1) "1 day" else "$days days"

/** "wed, oct 7" in english, and the locale's own order elsewhere. */
private fun dayFormat(): DateTimeFormatter {
    val locale = Locale.getDefault()
    return DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "EEEMMMd"), locale)
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Caption(heat: Heatmap, picked: Day?, modifier: Modifier) {
    val ink = LocalPalette.current
    if (picked != null) {
        Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Words(dayFormat().format(picked.date).lowercase(), size = 13.sp, weight = FontWeight.Medium)
            Words("— " + if (picked.seconds > 0) amount(picked.seconds) else "nothing logged.", size = 13.sp, color = ink.faint)
        }
        return
    }
    // At large font sizes the legend gets a line of its own.
    val large = LocalDensity.current.fontScale > 1.3f
    @Composable
    fun Legend() {
        Row(
            Modifier.clearAndSetSemantics {},
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Words("less", size = 11.sp, color = ink.faint)
            INK.forEachIndexed { i, a ->
                val color = if (i == 0) ink.wash else ink.accent.copy(alpha = a)
                Spacer(Modifier.size(9.dp).background(color, RoundedCornerShape(2.dp)))
            }
            Words("more", size = 11.sp, color = ink.faint)
        }
    }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        FlowRow(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(22.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Stat("today", amount(heat.today))
            Stat("this week", amount(heat.thisWeek))
            Stat("streak", streak(heat.streak))
            if (!large) {
                Spacer(Modifier.weight(1f))
                Legend()
            }
        }
        if (large) Legend()
    }
}

@Composable
private fun Stat(label: String, value: String) {
    val ink = LocalPalette.current
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Words(label, size = 13.sp, color = ink.faint)
        Words(value, size = 13.sp, weight = FontWeight.Medium)
    }
}
