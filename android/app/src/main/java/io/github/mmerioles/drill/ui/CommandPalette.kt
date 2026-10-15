package io.github.mmerioles.drill.ui

import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.core.Command
import io.github.mmerioles.drill.core.Commands
import io.github.mmerioles.drill.core.Hit
import io.github.mmerioles.drill.ink.LocalPalette

private val ROW = 44.dp
private const val ROWS = 8

/** Ids of the last commands run, most recent first; kept for the process. */
private val recent = ArrayList<String>()

/** Ctrl+K or a long press on the clock: type to find a command. [commands]
 *  builds the list for a query; [fallback] is the last row for a new tag. */
@Composable
fun CommandPalette(
    visible: Boolean,
    commands: () -> List<Command>,
    fallback: (String) -> Command?,
    close: () -> Unit,
) {
    val context = LocalContext.current
    val still = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    BackHandler(visible, close)
    AnimatedVisibility(
        visible,
        enter = if (still) EnterTransition.None else fadeIn(tween(120, easing = EaseOut)),
        exit = if (still) ExitTransition.None else fadeOut(tween(80)),
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = if (LocalPalette.current.dark) 0.2f else 0.06f))
                .pointerInput(Unit) { detectTapGestures { close() } }
                .windowInsetsPadding(WindowInsets.safeDrawing),
            contentAlignment = Alignment.TopCenter,
        ) {
            val phone = LocalConfiguration.current.screenWidthDp < 600
            // On a phone the keyboard takes the bottom half, so sit near the top.
            val top = if (phone) 12.dp else (LocalConfiguration.current.screenHeightDp * 0.2f).dp
            val shift = with(LocalDensity.current) { 6.dp.roundToPx() }
            Panel(
                Modifier
                    .padding(top = top, bottom = 16.dp)
                    .then(if (still) Modifier else Modifier.animateEnterExit(
                        enter = slideInVertically(tween(120, easing = EaseOut)) { -shift },
                    )),
                commands, fallback, close,
            )
        }
    }
}

@Composable
private fun Panel(modifier: Modifier, commands: () -> List<Command>, fallback: (String) -> Command?, close: () -> Unit) {
    val ink = LocalPalette.current
    var query by remember { mutableStateOf("") }
    var selected by remember { mutableIntStateOf(0) }
    val hits = remember(query) { Commands.rank(query, commands(), recent, fallback(query)) }
    val list = rememberLazyListState()
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current

    LaunchedEffect(Unit) {
        focus.requestFocus()
        keyboard?.show()
    }
    DisposableEffect(Unit) { onDispose { Typing.active = false } }
    LaunchedEffect(selected, hits) {
        val shown = list.layoutInfo.visibleItemsInfo
        val first = shown.firstOrNull()?.index ?: 0
        val last = shown.lastOrNull()?.index ?: 0
        when {
            selected <= first -> list.scrollToItem(selected)
            selected >= last -> list.scrollToItem((selected - shown.size + 2).coerceAtLeast(0))
        }
    }

    fun run(hit: Hit) {
        recent.remove(hit.command.id)
        recent.add(0, hit.command.id)
        if (recent.size > Commands.RECENT) recent.removeAt(recent.lastIndex)
        keyboard?.hide()
        close()
        hit.command.run()
    }
    fun move(by: Int) {
        if (hits.isNotEmpty()) selected = (selected + by).mod(hits.size)
    }

    Column(
        modifier
            .widthIn(max = 520.dp)
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .shadow(16.dp, RoundedCornerShape(14.dp), ambientColor = Color.Black.copy(alpha = 0.3f))
            .clip(RoundedCornerShape(14.dp))
            .background(ink.paper)
            .pointerInput(Unit) { detectTapGestures { } }
            .padding(6.dp),
    ) {
        BasicTextField(
            query,
            { query = it; selected = 0 },
            Modifier
                .fillMaxWidth()
                .focusRequester(focus)
                .onFocusChanged { if (it.isFocused) Typing.active = true }
                .onPreviewKeyEvent { e ->
                    val down = e.type == KeyEventType.KeyDown
                    when {
                        e.key == Key.DirectionDown || (e.isCtrlPressed && e.key == Key.N) -> { if (down) move(1); true }
                        e.key == Key.DirectionUp || (e.isCtrlPressed && e.key == Key.P) -> { if (down) move(-1); true }
                        e.key == Key.Escape -> { if (down) close(); true }
                        // On key up, so the activity never sees an enter after we close.
                        e.key == Key.Enter || e.key == Key.NumPadEnter -> {
                            if (!down) hits.getOrNull(selected)?.let(::run)
                            true
                        }
                        else -> false
                    }
                }
                .padding(horizontal = 12.dp, vertical = 12.dp),
            singleLine = true,
            textStyle = TextStyle(color = ink.ink, fontSize = 16.sp),
            cursorBrush = SolidColor(ink.ink),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { hits.getOrNull(selected)?.let(::run) }),
            decorationBox = { inner ->
                Box {
                    if (query.isEmpty()) BasicText("type a command…", style = TextStyle(color = ink.ink.copy(alpha = 0.28f), fontSize = 16.sp))
                    inner()
                }
            },
        )
        Box(Modifier.fillMaxWidth().height(1.dp).background(ink.ghost))
        if (hits.isEmpty()) {
            BasicText(
                "no matches", Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
                style = TextStyle(color = ink.faint, fontSize = 15.sp),
            )
        } else {
            LazyColumn(Modifier.padding(top = 4.dp).heightIn(max = ROW * ROWS), state = list) {
                itemsIndexed(hits, key = { _, h -> h.command.id }) { i, hit ->
                    Line(hit, i == selected, hover = { selected = i }) { run(hit) }
                }
            }
        }
    }
}

@Composable
private fun Line(hit: Hit, on: Boolean, hover: () -> Unit, run: () -> Unit) {
    val ink = LocalPalette.current
    val source = remember { MutableInteractionSource() }
    val hovered by source.collectIsHoveredAsState()
    LaunchedEffect(hovered) { if (hovered) hover() }
    val title = buildAnnotatedString {
        hit.command.title.forEachIndexed { i, c ->
            pushStyle(SpanStyle(color = if (i in hit.indices) ink.ink else ink.faint))
            append(c)
            pop()
        }
    }
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = ROW)
            .clip(RoundedCornerShape(8.dp))
            .background(if (on) ink.wash else Color.Transparent)
            .hoverable(source)
            .clickable(source, indication = null, role = Role.Button, onClick = run)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            title, Modifier.weight(1f), style = TextStyle(fontSize = 15.sp),
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        hit.command.hint?.let {
            BasicText(it, Modifier.padding(start = 12.dp), style = TextStyle(color = ink.faint, fontSize = 12.sp))
        }
    }
}
