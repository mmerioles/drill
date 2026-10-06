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
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle as DateStyle
import java.util.Locale
import kotlin.math.floor

// The year, as in HeatmapView.swift and the web app: the grid stretches to
// the width, a phone shows half a year, and a tapped day shows its time.

private const val GAP = 0.24f
private val INK = listOf(0f, 0.16f, 0.36f, 0.62f, 0.92f)

@Composable
fun YearView(model: AppModel) {
    val ink = LocalPalette.current
    var filter by rememberSaveable { mutableStateOf<String?>(null) }
    var picked by remember { mutableStateOf<Day?>(null) }
    val tags = model.tags(6)
    if (filter != null && filter !in tags) filter = null

    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Words("your year", size = 18.sp, weight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Link("all", size = 13.sp, on = filter == null) { filter = null }
                tags.forEach { t -> Link(t, size = 13.sp, on = filter == t) { filter = t } }
            }
        }
        Spacer(Modifier.height(10.dp))

        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val weeks = if (maxWidth < 520.dp) 26 else 53
            val today = LocalDate.now()
            val sessions = model.sessions.filter { filter == null || it.tag == filter }
            val heat = remember(sessions, weeks, today) { Heatmap.build(sessions, weeks, today) }
            val measurer = rememberTextMeasurer()
            val monthStyle = TextStyle(color = ink.faint, fontSize = 10.sp)
            val monthRow = 16.dp
            val pitchDp = maxWidth / (weeks - GAP)
            val height = monthRow + pitchDp * 7 - pitchDp * GAP

            Canvas(
                Modifier
                    .fillMaxWidth()
                    .height(height)
                    .pointerInput(heat) {
                        detectTapGestures { at ->
                            val pitch = size.width / (weeks - GAP)
                            val w = floor(at.x / pitch).toInt()
                            val d = floor((at.y - monthRow.toPx()) / pitch).toInt()
                            val day = heat.weeks.getOrNull(w)?.getOrNull(d)
                            picked = if (day == null || day.date == picked?.date) null else day
                        }
                    },
            ) {
                val pitch = size.width / (weeks - GAP)
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
                                if (w * pitch + text.size.width <= size.width) drawText(text, topLeft = Offset(w * pitch, 0f))
                            }
                            lastMonth = month
                        }
                    }
                    week.forEachIndexed { d, day ->
                        if (day == null) return@forEachIndexed
                        val x = w * pitch
                        val y = top + d * pitch
                        val color = if (day.level > 0) ink.accent.copy(alpha = INK[day.level]) else ink.wash
                        drawPath(Doodle.square(x, y, cell, ((w * 7 + d) * 31 + 7).toLong(), cell / 12 * 0.35f), color)
                        val outline = when (day.date) {
                            picked?.date -> ink.faint
                            today -> ink.ink
                            else -> null
                        }
                        if (outline != null) {
                            val pad = 1.75.dp.toPx()
                            drawRoundRect(
                                outline, Offset(x - pad, y - pad), Size(cell + pad * 2, cell + pad * 2),
                                CornerRadius(3.dp.toPx()), style = Stroke(1.1.dp.toPx()),
                            )
                        }
                    }
                }
            }
            Caption(heat, picked, Modifier.padding(top = height + 12.dp))
        }
    }
}

private val dayFormat = DateTimeFormatter.ofPattern("EEE, MMM d")

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Caption(heat: Heatmap, picked: Day?, modifier: Modifier) {
    val ink = LocalPalette.current
    if (picked != null) {
        Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Words(dayFormat.format(picked.date).lowercase(), size = 13.sp, weight = FontWeight.Medium)
            Words("— " + if (picked.seconds > 0) amount(picked.seconds) else "nothing logged.", size = 13.sp, color = ink.faint)
        }
        return
    }
    FlowRow(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(18.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Stat("today", amount(heat.today))
        Stat("this week", amount(heat.thisWeek))
        Stat("streak", if (heat.streak == 1) "1 day" else "${heat.streak} days")
        Spacer(Modifier.weight(1f))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Words("less", size = 12.sp, color = ink.faint)
            INK.forEachIndexed { i, a ->
                val color = if (i == 0) ink.wash else ink.accent.copy(alpha = a)
                Spacer(Modifier.size(9.dp).background(color, RoundedCornerShape(2.dp)))
            }
            Words("more", size = 12.sp, color = ink.faint)
        }
    }
}

@Composable
private fun Stat(label: String, value: String) {
    val ink = LocalPalette.current
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Words(label, size = 13.sp, color = ink.faint)
        Words(value, size = 13.sp, weight = FontWeight.SemiBold)
    }
}
