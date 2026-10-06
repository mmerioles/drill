package io.github.mmerioles.tetodoro.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.tetodoro.AppModel
import io.github.mmerioles.tetodoro.core.Phase
import io.github.mmerioles.tetodoro.core.Status
import io.github.mmerioles.tetodoro.ink.Doodle
import io.github.mmerioles.tetodoro.ink.LocalPalette

// Copy, as in TetodoroApp/Copy.swift.

fun clock(ms: Long): String {
    val total = ((ms + 999) / 1000).toInt()
    val h = total / 3600
    val m = total % 3600 / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}

fun amount(seconds: Double): String {
    val minutes = (seconds / 60).toInt()
    val h = minutes / 60
    val m = minutes % 60
    return when {
        h == 0 -> "${m}m"
        m == 0 -> "${h}h"
        else -> "${h}h ${m}m"
    }
}

@Composable
fun TimerView(model: AppModel, now: Long, tick: Long, toggle: () -> Unit) {
    val ink = LocalPalette.current
    val timer = model.timer
    val status = when {
        timer.phase == Phase.Focus && timer.status is Status.Idle -> ""
        timer.status is Status.Paused -> "paused"
        timer.phase == Phase.Focus -> "focus"
        timer.phase == Phase.ShortBreak -> "break"
        else -> "long break"
    }

    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(270.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                val line = 2.6.dp.toPx()
                val ring = Doodle.ring(size.minDimension, model.progress(now), tick, line)
                drawPath(ring.track, ink.ghost, style = Stroke(
                    width = 1.4.dp.toPx(), cap = StrokeCap.Round,
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(1.5.dp.toPx(), 6.dp.toPx())),
                ))
                ring.arc?.let {
                    drawPath(it, ink.accent, style = Stroke(width = line, cap = StrokeCap.Round, join = StrokeJoin.Round))
                }
                ring.tip?.let { drawCircle(ink.accent, 3.1.dp.toPx(), it) }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Words(status, Modifier.heightIn(min = 18.dp), size = 13.sp, color = ink.faint)
                BasicText(
                    clock(model.remaining(now)),
                    style = TextStyle(
                        color = ink.ink, fontSize = 58.sp, fontWeight = FontWeight.Bold,
                        fontFeatureSettings = "tnum", letterSpacing = (-0.5).sp,
                    ),
                )
                Row(Modifier.height(6.dp), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    repeat(model.config.longBreakEvery) { i ->
                        val on = i < model.cyclePosition
                        Box(
                            Modifier.size(6.dp).border(1.dp, if (on) ink.ink else ink.faint, CircleShape)
                                .background(if (on) ink.ink else ink.paper.copy(alpha = 0f), CircleShape),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(30.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Words("studying", color = ink.faint)
            Field(model.tag, model::updateTag, Modifier.width(150.dp), placeholder = "anything")
        }
        val current = model.tag.trim().lowercase()
        Row(Modifier.heightIn(min = 30.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            model.tags().filter { it != current }.take(4).forEach { t ->
                Link(t, size = 12.sp) { model.updateTag(t) }
            }
        }

        Spacer(Modifier.height(20.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(28.dp)) {
            val idle = timer.status is Status.Idle
            Box(Modifier.width(44.dp), contentAlignment = Alignment.CenterEnd) {
                if (!idle) Link("reset", action = model::reset)
            }
            Capsule(
                when (timer.status) {
                    is Status.Running -> "pause"
                    Status.Idle -> "start"
                    is Status.Paused -> "resume"
                },
                action = toggle,
            )
            Box(Modifier.width(44.dp), contentAlignment = Alignment.CenterStart) {
                Link("skip", action = model::skip)
            }
        }
    }
}
