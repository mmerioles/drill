package io.github.mmerioles.tetodoro.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import io.github.mmerioles.tetodoro.ink.Doodle
import io.github.mmerioles.tetodoro.ink.LocalPalette

// One ink capsule per screen; everything else is a faint word.

@Composable
fun Words(
    text: String,
    modifier: Modifier = Modifier,
    size: TextUnit = 15.sp,
    weight: FontWeight = FontWeight.Normal,
    color: Color = LocalPalette.current.ink,
) {
    BasicText(text, modifier, style = TextStyle(color = color, fontSize = size, fontWeight = weight))
}

/** A faint word that does something; [on] marks the chosen one in a row. */
@Composable
fun Link(text: String, modifier: Modifier = Modifier, size: TextUnit = 14.sp, on: Boolean = false, action: () -> Unit) {
    val ink = LocalPalette.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val color by animateColorAsState(if (on || pressed) ink.ink else ink.faint, label = "link")
    BasicText(
        text,
        modifier
            .clickable(source, indication = null, role = Role.Button, onClick = action)
            .padding(vertical = 6.dp),
        style = TextStyle(color = color, fontSize = size, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal),
    )
}

@Composable
fun Capsule(text: String, modifier: Modifier = Modifier, small: Boolean = false, enabled: Boolean = true, action: () -> Unit) {
    val ink = LocalPalette.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.96f else 1f, label = "press")
    Box(
        modifier
            .scale(scale)
            .clip(CircleShape)
            .background(if (enabled) ink.ink else ink.faint)
            .clickable(source, indication = null, enabled = enabled, role = Role.Button, onClick = action)
            .widthIn(min = if (small) 0.dp else 128.dp)
            .padding(horizontal = if (small) 28.dp else 42.dp, vertical = if (small) 10.dp else 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Words(text, size = if (small) 14.sp else 16.sp, weight = FontWeight.SemiBold, color = ink.paper)
    }
}

/** The drill mark, boiling while [tick] moves. */
@Composable
fun DrillMark(tick: Long, modifier: Modifier = Modifier, size: Dp = 22.dp) {
    val accent = LocalPalette.current.accent
    Canvas(modifier.size(size)) {
        val s = this.size.minDimension
        drawPath(
            Doodle.drill(s, tick), accent,
            style = Stroke(width = s * 1.8f / 22, cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
    }
}

/** A card over the screen, like the web app's dialogs. */
@Composable
fun Sheet(onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    val ink = LocalPalette.current
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .padding(16.dp)
                .widthIn(max = 440.dp)
                .fillMaxWidth()
                .clip(RoundedCornerShape(22.dp))
                .background(ink.paper)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 22.dp, vertical = 22.dp),
            content = content,
        )
    }
}

/** A run of rows on a faint wash. */
@Composable
fun Group(content: @Composable ColumnScope.() -> Unit) {
    val ink = LocalPalette.current
    Column(
        Modifier
            .padding(bottom = 14.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(ink.wash)
            .padding(horizontal = 16.dp, vertical = 4.dp),
        content = content,
    )
}

@Composable
fun SettingRow(label: String, content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 46.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Words(label, Modifier.weight(1f))
        content()
    }
}

@Composable
fun SwitchRow(label: String, on: Boolean, change: (Boolean) -> Unit) {
    val ink = LocalPalette.current
    val knob by animateFloatAsState(if (on) 1f else 0f, label = "switch")
    Box(
        Modifier
            .fillMaxWidth()
            .clickable(remember { MutableInteractionSource() }, null, role = Role.Switch) { change(!on) },
    ) {
        SettingRow(label) {
            Canvas(Modifier.size(width = 40.dp, height = 24.dp)) {
                val h = size.height
                drawRoundRect(
                    if (on) ink.ink else ink.ghost,
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(h / 2),
                )
                val r = h / 2 - 3.dp.toPx()
                drawCircle(ink.paper, r, Offset(h / 2 + knob * (size.width - h), h / 2))
            }
        }
    }
}

/** A number with a faint − and + either side. */
@Composable
fun StepperRow(label: String, value: Int, range: IntRange, step: Int = 1, unit: String = "", change: (Int) -> Unit) {
    SettingRow(label) {
        Link("−", size = 18.sp) { change((value - step).coerceIn(range)) }
        Words(if (unit.isEmpty()) "$value" else "$value $unit", Modifier.widthIn(min = 56.dp),
            weight = FontWeight.Medium)
        Link("+", size = 18.sp) { change((value + step).coerceIn(range)) }
    }
}

/** A text field drawn as a single underline. */
@Composable
fun Field(
    value: String,
    change: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    password: Boolean = false,
    keyboard: KeyboardType = KeyboardType.Text,
    weight: FontWeight = FontWeight.Medium,
    done: () -> Unit = {},
) {
    val ink = LocalPalette.current
    val focus = LocalFocusManager.current
    BasicTextField(
        value, change,
        modifier.drawBehind {
            val y = size.height
            drawLine(ink.ghost, Offset(0f, y), Offset(size.width, y), 1.dp.toPx())
        }.padding(bottom = 4.dp),
        singleLine = true,
        textStyle = TextStyle(color = ink.ink, fontSize = 15.sp, fontWeight = weight),
        cursorBrush = SolidColor(ink.ink),
        visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = if (password) KeyboardType.Password else keyboard, autoCorrectEnabled = false),
        keyboardActions = KeyboardActions { focus.clearFocus(); done() },
        decorationBox = { inner ->
            Box {
                if (value.isEmpty()) Words(placeholder, color = ink.ink.copy(alpha = 0.28f))
                inner()
            }
        },
    )
}
