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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.core.Copy
import io.github.mmerioles.drill.core.IntervalPhase
import io.github.mmerioles.drill.core.Phase
import io.github.mmerioles.drill.core.Status
import io.github.mmerioles.drill.ink.Doodle
import io.github.mmerioles.drill.ink.LocalPalette

/** The ring, clock, tag and controls, sized from the ring's diameter [ring].
 *  [now] and [boil] are read only where drawn, so a tick redraws the ring
 *  and digits, not the whole view. [phone] tightens the rhythm a step. */
@Composable
fun TimerView(
    model: AppModel, ring: Dp, phone: Boolean,
    now: () -> Long, boil: () -> Long, toggle: () -> Unit, palette: () -> Unit,
) {
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

    // The readout, in proportion to the ring.
    val r = ring.value
    val statusSize = (r * 0.055f).coerceIn(13f, 17f).sp
    val clockSize = (r * 0.22f).sp
    val roundSize = (r * 0.055f).sp
    val mark = ring * 0.08f

    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .size(ring)
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
            // Every piece has a fixed height, so the clock never moves
            // between modes or when the status word comes and goes.
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Words(status, Modifier.heightIn(min = lineOf(statusSize)), size = statusSize, color = ink.faint)
                Spacer(Modifier.height(ring * 0.03f))
                Digits(model, now, ring, clockSize)
                Spacer(Modifier.height(ring * 0.04f))
                // The mark slot: runner or sneaker over the round line, or the cycle dots.
                Column(Modifier.height(mark + 4.dp + lineOf(roundSize)), horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.height(mark), contentAlignment = Alignment.Center) {
                        if (intervals) {
                            Glyph(workout.phase, boil, mark)
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
                    if (intervals) {
                        Spacer(Modifier.height(4.dp))
                        // Keeps its room while idle, so the digits don't jump at start.
                        val line by remember(model) { derivedStateOf { Copy.workout(model.workout.round, model.elapsed(now())) } }
                        Words(line, Modifier.alpha(if (idle) 0f else 1f), size = roundSize, color = ink.faint)
                    }
                }
            }
        }

        Spacer(Modifier.height(if (phone) 32.dp else 40.dp))
        if (!intervals) {
            Row(Modifier.height(32.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Words("studying", Modifier.alignByBaseline(), color = ink.faint)
                Field(model.tag, model::updateTag, Modifier.alignByBaseline().width(150.dp), placeholder = "anything", label = "studying")
            }
            Spacer(Modifier.height(8.dp))
            val current = model.tag.trim().lowercase()
            Row(Modifier.height(SUGGESTIONS), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                model.recentTags.filter { it != current && it != "intervals" }.take(4).forEach { t ->
                    Link(t, size = 13.sp, compact = true, height = SUGGESTIONS) { model.updateTag(t) }
                }
            }
            Spacer(Modifier.height(32.dp))
        }

        // Equal-weight sides keep the capsule centred at any font size; the
        // links sit 32 from its edges.
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(32.dp)) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                if (!idle) Link(if (intervals) "done" else "reset", compact = true, action = model::reset)
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
                Link("skip", compact = true, action = model::skip)
            }
        }
    }
}

private val SUGGESTIONS = 20.dp

/** One line of text at [size], in dp at the user's font scale. */
@Composable
private fun lineOf(size: TextUnit): Dp = with(LocalDensity.current) { size.toDp() * 1.2f }

/** The runner or the sneaker, boiling like the ring while it runs. */
@Composable
private fun Glyph(phase: IntervalPhase, boil: () -> Long, size: Dp) {
    val ink = LocalPalette.current
    Canvas(Modifier.size(size)) {
        val s = this.size.minDimension
        val seed = boil() + if (phase == IntervalPhase.Run) 21 else 29
        val paths = if (phase == IntervalPhase.Run) Doodle.runner(s, seed) else Doodle.sneaker(s, seed)
        val style = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
        paths.forEach { drawPath(it, ink.ink, style = style) }
    }
}

/** The countdown, 0.22 of the ring; shrinks to fit it at large font sizes. */
@Composable
private fun Digits(model: AppModel, now: () -> Long, ring: Dp, size: TextUnit) {
    val ink = LocalPalette.current
    val text by remember(model) { derivedStateOf { Copy.clock(model.remaining(now())) } }
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val style = remember(text.length, density, ink, size) {
        val base = TextStyle(
            color = ink.ink, fontSize = size, fontWeight = FontWeight.Bold,
            fontFeatureSettings = "tnum", letterSpacing = (-0.5).sp,
        )
        val room = with(density) { (ring * 0.74f).toPx() }
        val wide = measurer.measure(text.map { if (it.isDigit()) '0' else it }.joinToString(""), base).size.width
        if (wide <= room) base else base.copy(fontSize = base.fontSize * (room / wide))
    }
    BasicText(text, Modifier.clearAndSetSemantics {}, style = style, softWrap = false, maxLines = 1)
}
