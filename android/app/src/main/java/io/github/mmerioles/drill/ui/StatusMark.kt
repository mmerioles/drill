package io.github.mmerioles.drill.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import io.github.mmerioles.drill.ink.LocalPalette

private val Green = Color(0xFF3DA35D)
private val Yellow = Color(0xFFE8B931)

/** How something stands, in one small mark, like StatusMark.swift. */
enum class Mark { None, Working, Pending, Done }

/** A spinner while working, a yellow dot while it waits on you, a green
 *  check once it's done. Changes between them pop, with a little spring.
 *  [breathing] gives the yellow dot a slow breath, for when it's waiting on
 *  something that'll happen by itself. */
@Composable
fun StatusMark(status: Mark, modifier: Modifier = Modifier, breathing: Boolean = false, size: Dp = 14.dp) {
    val ink = LocalPalette.current
    AnimatedContent(
        status,
        modifier.size(size),
        transitionSpec = {
            (scaleIn(spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessMediumLow), initialScale = 0.4f) +
                fadeIn(tween(160))) togetherWith (scaleOut(tween(160), targetScale = 0.6f) + fadeOut(tween(160)))
        },
        contentAlignment = Alignment.Center,
        label = "mark",
    ) { s ->
        Box(Modifier.size(size), contentAlignment = Alignment.Center) {
            when (s) {
                Mark.Working -> {
                    val turn by rememberInfiniteTransition(label = "spin").animateFloat(
                        0f, 360f, infiniteRepeatable(tween(800, easing = LinearEasing)), label = "turn",
                    )
                    Canvas(Modifier.size(size * 0.86f).graphicsLayer { rotationZ = turn }) {
                        drawArc(
                            ink.faint, 0f, 260f, useCenter = false,
                            style = Stroke(1.6.dp.toPx(), cap = StrokeCap.Round),
                        )
                    }
                }
                Mark.Done -> Canvas(Modifier.size(size)) {
                    drawCircle(Green)
                    val w = this.size.width
                    drawPath(
                        Path().apply {
                            moveTo(w * 0.28f, w * 0.52f)
                            lineTo(w * 0.44f, w * 0.68f)
                            lineTo(w * 0.73f, w * 0.36f)
                        },
                        Color.White,
                        style = Stroke(w * 0.115f, cap = StrokeCap.Round, join = StrokeJoin.Round),
                    )
                }
                Mark.Pending -> Dot(size * 0.71f, breathing)
                Mark.None -> Unit
            }
        }
    }
}

@Composable
private fun Dot(size: Dp, breathing: Boolean) {
    val breath = if (breathing) {
        rememberInfiniteTransition(label = "breath").animateFloat(
            1f, 0.78f, infiniteRepeatable(tween(1100, easing = FastOutSlowInEasing), RepeatMode.Reverse),
            label = "breath",
        ).value
    } else {
        1f
    }
    Box(
        Modifier.size(size)
            .graphicsLayer { scaleX = breath; scaleY = breath; alpha = 0.6f + 0.4f * (breath - 0.78f) / 0.22f }
            .clip(CircleShape)
            .background(Yellow),
    )
}
