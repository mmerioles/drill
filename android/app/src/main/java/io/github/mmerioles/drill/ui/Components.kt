package io.github.mmerioles.drill.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.ink.LocalPalette
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

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

/** Minimum touch size, however small the word. */
val TouchTarget = 48.dp

/** The dot that says an update is waiting. */
val UpdateYellow = Color(0xFFF2C21B)

/** A faint word that does something. [on] marks the chosen one; [selectable]
 *  makes it a tab; [description] replaces [text] for TalkBack; [primary] is
 *  ink and heavier; [compact] is only as wide as the word and [height] is
 *  how tall it lays out (Compose still widens the touch area to 48);
 *  [badge] adds the update dot. */
@Composable
fun Link(
    text: String,
    modifier: Modifier = Modifier,
    size: TextUnit = 15.sp,
    on: Boolean = false,
    selectable: Boolean = false,
    enabled: Boolean = true,
    description: String? = null,
    primary: Boolean = false,
    compact: Boolean = false,
    height: Dp = TouchTarget,
    badge: Boolean = false,
    action: () -> Unit,
) {
    val ink = LocalPalette.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val color by animateColorAsState(
        when {
            !enabled -> ink.ghost
            on || pressed || primary -> ink.ink
            else -> ink.faint
        },
        label = "link",
    )
    val touch = if (selectable) {
        Modifier.selectable(on, source, indication = null, enabled = enabled, role = Role.Tab, onClick = action)
    } else {
        Modifier.clickable(source, indication = null, enabled = enabled, role = Role.Button, onClick = action)
    }
    Box(
        modifier
            .then(touch)
            .then(if (description != null) Modifier.semantics { contentDescription = description } else Modifier)
            .defaultMinSize(minWidth = if (compact) 0.dp else TouchTarget, minHeight = height),
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text,
            if (badge) Modifier.drawBehind {
                val r = 3.dp.toPx()
                drawCircle(UpdateYellow, r, Offset(this.size.width + r + 2.dp.toPx(), r))
            } else Modifier,
            style = TextStyle(
                color = color, fontSize = size,
                fontWeight = when {
                    on -> FontWeight.SemiBold
                    primary -> FontWeight.Medium
                    else -> FontWeight.Normal
                },
            ),
        )
    }
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
            .defaultMinSize(minHeight = if (small) 40.dp else 48.dp)
            .widthIn(min = if (small) 0.dp else 128.dp)
            .padding(horizontal = if (small) 28.dp else 42.dp, vertical = if (small) 8.dp else 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Words(text, size = if (small) 14.sp else 16.sp, weight = FontWeight.SemiBold, color = ink.paper)
    }
}

@Composable
fun SheetTitle(text: String, modifier: Modifier = Modifier) {
    Words(text, modifier.semantics { heading() }, size = 20.sp, weight = FontWeight.SemiBold)
}

@OptIn(ExperimentalMaterial3Api::class)
@Stable
class SheetHandle internal constructor(
    internal val state: SheetState,
    private val scope: CoroutineScope,
    internal val dismissed: () -> Unit,
) {
    /** Slides the sheet down, then runs [then] (by default, closes it). */
    fun close(then: () -> Unit = dismissed) {
        scope.launch { state.hide() }.invokeOnCompletion { then() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun rememberSheet(onDismiss: () -> Unit): SheetHandle {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val latest by rememberUpdatedState(onDismiss)
    return remember(state, scope) { SheetHandle(state, scope) { latest() } }
}

/** A Material bottom sheet on drill's paper: the phone's width, 440 on a tablet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Sheet(handle: SheetHandle, content: @Composable ColumnScope.() -> Unit) {
    val ink = LocalPalette.current
    val wide = LocalConfiguration.current.screenWidthDp >= 600
    ModalBottomSheet(
        onDismissRequest = handle.dismissed,
        sheetState = handle.state,
        sheetMaxWidth = if (wide) 440.dp else Dp.Unspecified,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        containerColor = ink.paper,
        contentColor = ink.ink,
        scrimColor = Color.Black.copy(alpha = 0.32f),
        tonalElevation = 0.dp,
        dragHandle = {
            Box(
                Modifier
                    .padding(vertical = 16.dp)
                    .size(width = 32.dp, height = 4.dp)
                    .background(ink.ink.copy(alpha = 0.4f), CircleShape),
            )
        },
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
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
            .padding(bottom = 24.dp)
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
        Modifier.fillMaxWidth().heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Words(label, Modifier.weight(1f))
        content()
    }
}

/** A switch in ink; the whole row toggles. */
@Composable
fun SwitchRow(label: String, on: Boolean, change: (Boolean) -> Unit) {
    val ink = LocalPalette.current
    val source = remember { MutableInteractionSource() }
    Box(
        Modifier
            .fillMaxWidth()
            .toggleable(on, source, null, role = Role.Switch, onValueChange = change),
    ) {
        SettingRow(label) {
            Switch(
                on, onCheckedChange = null, interactionSource = source,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = ink.paper,
                    checkedTrackColor = ink.ink,
                    checkedBorderColor = ink.ink,
                    uncheckedThumbColor = ink.faint,
                    uncheckedTrackColor = ink.paper.copy(alpha = 0f),
                    uncheckedBorderColor = ink.faint,
                ),
            )
        }
    }
}

/** A pill of choices with an ink thumb that slides to the chosen one. */
@Composable
fun <T> Segmented(options: List<T>, selected: T, label: (T) -> String, choose: (T) -> Unit) {
    val ink = LocalPalette.current
    val index = options.indexOf(selected).coerceAtLeast(0)
    BoxWithConstraints(
        Modifier
            .height(36.dp)
            .clip(CircleShape)
            .background(ink.ink.copy(alpha = 0.06f))
            .selectableGroup(),
    ) {
        val segment = 76.dp
        val x by animateDpAsState(segment * index, label = "segment")
        Box(Modifier.offset(x = x).width(segment).fillMaxHeight().padding(3.dp).background(ink.ink, CircleShape))
        Row {
            options.forEachIndexed { i, option ->
                val chosen = i == index
                val color by animateColorAsState(if (chosen) ink.paper else ink.faint, label = "segment text")
                Box(
                    Modifier
                        .width(segment)
                        .fillMaxHeight()
                        .selectable(chosen, remember { MutableInteractionSource() }, null, role = Role.RadioButton) { choose(option) },
                    contentAlignment = Alignment.Center,
                ) {
                    BasicText(label(option), style = TextStyle(color = color, fontSize = 14.sp, fontWeight = FontWeight.Medium))
                }
            }
        }
    }
}

/** A number between − and +; [less] and [more] are their TalkBack names. */
@Composable
fun StepperRow(
    label: String, value: Int, range: IntRange, step: Int = 1, unit: String = "",
    less: String = "less $label", more: String = "more $label",
    change: (Int) -> Unit,
) {
    SettingRow(label) {
        Link("−", size = 18.sp, enabled = value > range.first, description = less) { change((value - step).coerceIn(range)) }
        BasicText(
            if (unit.isEmpty()) "$value" else "$value $unit", Modifier.widthIn(min = 56.dp),
            style = TextStyle(
                color = LocalPalette.current.ink, fontSize = 15.sp, textAlign = TextAlign.Center,
                fontFeatureSettings = "tnum",
            ),
        )
        Link("+", size = 18.sp, enabled = value < range.last, description = more) { change((value + step).coerceIn(range)) }
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
    enabled: Boolean = true,
    label: String? = null,
    done: () -> Unit = {},
) {
    val ink = LocalPalette.current
    val focus = LocalFocusManager.current
    var had by remember { mutableStateOf(false) }
    val line by animateDpAsState(if (had) 2.dp else 1.dp, label = "underline")
    val lineColor by animateColorAsState(if (had) ink.ink else ink.ghost, label = "underline color")
    BasicTextField(
        value, change,
        modifier
            .onFocusChanged { if (it.isFocused) Typing.active = true else if (had) Typing.active = false; had = it.isFocused }
            .then(if (label != null) Modifier.semantics { contentDescription = label } else Modifier)
            .drawBehind {
                val w = line.toPx()
                val y = size.height - w / 2
                drawLine(lineColor, Offset(0f, y), Offset(size.width, y), w)
            }.padding(bottom = 6.dp),
        enabled = enabled,
        singleLine = true,
        textStyle = TextStyle(color = if (enabled) ink.ink else ink.faint, fontSize = 15.sp, fontWeight = weight),
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

/** Whether a text field has focus, so space and enter type instead of toggling the timer. */
object Typing {
    var active = false
}
