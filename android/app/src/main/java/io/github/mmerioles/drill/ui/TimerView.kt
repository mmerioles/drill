package io.github.mmerioles.drill.ui

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
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.core.Copy
import io.github.mmerioles.drill.core.IntervalPhase
import io.github.mmerioles.drill.core.Phase
import io.github.mmerioles.drill.core.Status
import io.github.mmerioles.drill.ink.Doodle
import io.github.mmerioles.drill.ink.LocalPalette

/** The ring, clock, tag and controls. [now] and [boil] are read only where
 *  drawn, so a tick redraws the ring and digits, not the whole view. */
@Composable
fun TimerView(model: AppModel, now: () -> Long, boil: () -> Long, toggle: () -> Unit, palette: () -> Unit) {
    val ink = LocalPalette.current
    val focus = LocalFocusManager.current
    val haptics = LocalHapticFeedback.current
    val openPalette by rememberUpdatedState(palette)
    val timer = model.timer
    val workout = model.workout
    val intervals = model.isIntervals
    val idle = model.status is Status.Idle
    val paused = model.status is Status.Paused
    val phaseName = if (intervals) Copy.phaseName(workout.phase) else Copy.phaseName(timer.phase)
    val status = when {
        paused -> "paused"
        idle && (intervals || timer.phase == Phase.Focus) -> ""
        else -> phaseName
    }
    // Changes once a minute, so TalkBack isn't re-read every second.
    val left by remember(model) { derivedStateOf { Copy.spokenLeft(model.remaining(now())) } }
    val spoken = phaseName + (if (paused) ", paused" else "") + ", " + left

    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .size(RING)
                .clearAndSetSemantics {
                    contentDescription = spoken
                    if (idle) onClick("switch to ${Copy.modeName(!intervals)}") { model.switchMode(); true }
                    onLongClick("commands") { palette(); true }
                }
                // A tap dismisses the keyboard and, between blocks, switches
                // mode; a long press opens the palette.
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = { focus.clearFocus(); model.switchMode() },
                        onLongPress = { haptics.performHapticFeedback(HapticFeedbackType.LongPress); openPalette() },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            Canvas(Modifier.fillMaxSize()) {
                val line = 2.6.dp.toPx()
                val ring = Doodle.ring(size.minDimension, model.progress(now()), boil(), line)
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
                Digits(model, now)
                if (intervals) {
                    Glyph(workout.phase, boil)
                    // Keeps its room while idle, so the digits don't jump at start.
                    val line by remember(model) { derivedStateOf { Copy.workout(model.workout.round, model.elapsed(now())) } }
                    Words(line, Modifier.alpha(if (idle) 0f else 1f), size = 13.sp, color = ink.faint)
                } else {
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
        }

        Spacer(Modifier.height(30.dp))
        if (!intervals) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Words("studying", Modifier.alignByBaseline(), color = ink.faint)
                Field(model.tag, model::updateTag, Modifier.alignByBaseline().width(150.dp), placeholder = "anything", label = "studying")
            }
            val current = model.tag.trim().lowercase()
            Row(Modifier.heightIn(min = TouchTarget), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                model.recentTags.filter { it != current }.take(4).forEach { t ->
                    Link(t, size = 12.sp) { model.updateTag(t) }
                }
            }
            Spacer(Modifier.height(8.dp))
        }

        // Equal-weight sides keep the capsule centred at any font size.
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                if (!idle) Link(if (intervals) "done" else "reset", action = model::reset)
            }
            Capsule(
                when (model.status) {
                    is Status.Running -> "pause"
                    Status.Idle -> "start"
                    is Status.Paused -> "resume"
                },
                action = toggle,
            )
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                Link("skip", action = model::skip)
            }
        }
    }
}

private val RING = 270.dp

/** The runner or the sneaker, boiling like the ring while it runs. */
@Composable
private fun Glyph(phase: IntervalPhase, boil: () -> Long) {
    val ink = LocalPalette.current
    Canvas(Modifier.size(22.dp)) {
        val s = size.minDimension
        val seed = boil() + if (phase == IntervalPhase.Run) 21 else 29
        val paths = if (phase == IntervalPhase.Run) Doodle.runner(s, seed) else Doodle.sneaker(s, seed)
        val style = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
        paths.forEach { drawPath(it, ink.ink, style = style) }
    }
}

/** The countdown; shrinks to fit the ring at large font sizes. */
@Composable
private fun Digits(model: AppModel, now: () -> Long) {
    val ink = LocalPalette.current
    val text by remember(model) { derivedStateOf { Copy.clock(model.remaining(now())) } }
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val style = remember(text.length, density, ink) {
        val base = TextStyle(
            color = ink.ink, fontSize = 58.sp, fontWeight = FontWeight.Bold,
            fontFeatureSettings = "tnum", letterSpacing = (-0.5).sp,
        )
        val room = with(density) { (RING * 0.74f).toPx() }
        val wide = measurer.measure(text.map { if (it.isDigit()) '0' else it }.joinToString(""), base).size.width
        if (wide <= room) base else base.copy(fontSize = base.fontSize * (room / wide))
    }
    BasicText(text, Modifier.clearAndSetSemantics {}, style = style, softWrap = false, maxLines = 1)
}
