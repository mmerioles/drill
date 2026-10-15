package io.github.mmerioles.drill.ui

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color as AndroidColor
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.DrillApp
import io.github.mmerioles.drill.Theme
import io.github.mmerioles.drill.core.Command
import io.github.mmerioles.drill.core.Copy
import io.github.mmerioles.drill.core.Status
import io.github.mmerioles.drill.data.Sync
import io.github.mmerioles.drill.data.Updater
import io.github.mmerioles.drill.ink.Doodle
import io.github.mmerioles.drill.ink.LocalPalette
import io.github.mmerioles.drill.ink.Palette
import kotlinx.coroutines.delay
import java.time.LocalDate

class MainActivity : ComponentActivity() {
    private val model by lazy { DrillApp.model(this) }
    private val palette = mutableStateOf(false)

    /** Midnight or a clock/zone change moves the year's "today". */
    private val clockChanged = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = model.reload()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(bars(model.theme), bars(model.theme))
        super.onCreate(savedInstanceState)
        model.updater.start()
        model.pinNightMode()
        setContent { App(model, palette) }
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_DATE_CHANGED)
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
        }
        ContextCompat.registerReceiver(this, clockChanged, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    override fun onStop() {
        unregisterReceiver(clockChanged)
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        model.catchUp()
        model.sync.cameBack()
        model.reload()
        model.updater.resume()
        model.updater.checkIfStale(15 * 60_000L)
    }

    /** Ctrl+K opens the palette, even from the tag field. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_K && event.isCtrlPressed) {
            if (event.action == KeyEvent.ACTION_DOWN) palette.value = true
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    /** With a keyboard: space or enter starts and pauses, unless typing. */
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        val key = keyCode == KeyEvent.KEYCODE_SPACE || keyCode == KeyEvent.KEYCODE_ENTER ||
            keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER
        if (key && !Typing.active && !palette.value && event.hasNoModifiers()) {
            model.toggle()
            return true
        }
        return super.onKeyUp(keyCode, event)
    }
}

/** Transparent system bars with icons for drill's theme, not the phone's. */
fun bars(theme: Theme) = if (theme == Theme.Dark) SystemBarStyle.dark(AndroidColor.TRANSPARENT)
else SystemBarStyle.light(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT)

enum class Open { None, Settings, Account, Inspo }

@Composable
fun App(model: AppModel, palette: MutableState<Boolean>) {
    val dark = model.theme == Theme.Dark
    val activity = LocalContext.current as ComponentActivity
    SideEffect { activity.enableEdgeToEdge(bars(model.theme), bars(model.theme)) }
    CompositionLocalProvider(LocalPalette provides if (dark) Palette.dark else Palette.light) {
        Screen(model, palette)
    }
}

@Composable
fun Screen(model: AppModel, palette: MutableState<Boolean>) {
    val ink = LocalPalette.current
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var open by rememberSaveable { mutableStateOf(Open.None) }
    var filter by rememberSaveable { mutableStateOf<String?>(null) }
    var picked by remember { mutableStateOf<LocalDate?>(null) }

    // Ticks on each second boundary while running and on screen; only the
    // ring and digits read it. At zero, catch up rather than wait for the alarm.
    val clock = remember { mutableLongStateOf(System.currentTimeMillis()) }
    val running = model.status as? Status.Running
    LaunchedEffect(running) {
        clock.longValue = System.currentTimeMillis()
        if (running == null) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                val now = System.currentTimeMillis()
                clock.longValue = now
                if (now >= running.endsAt) {
                    model.catchUp()
                    break
                }
                delay(Copy.untilNextSecond(running.endsAt - now) + 4)
            }
        }
    }

    // The hand-drawn boil: a slower beat, read only while drawing.
    val still = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val boil = remember { mutableLongStateOf(0L) }
    val boiling = running != null && !still
    LaunchedEffect(boiling) {
        if (!boiling) {
            boil.longValue = 0L
            return@LaunchedEffect
        }
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                val now = System.currentTimeMillis()
                boil.longValue = now / Doodle.BOIL_MS
                delay(Doodle.BOIL_MS - now % Doodle.BOIL_MS)
            }
        }
    }

    // Sync every five minutes while signed in, auto syncing and on screen.
    val looping = model.sync.isSignedIn && model.sync.auto
    LaunchedEffect(looping) {
        if (!looping) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                delay(5 * 60_000L)
                model.sync.syncNow()
            }
        }
    }

    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        model.catchUp()
    }
    val toggle = {
        if (model.status is Status.Idle && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        model.toggle()
    }

    val focus = LocalFocusManager.current
    Box(
        Modifier
            .fillMaxSize()
            .background(ink.paper)
            // A tap outside the tag field dismisses the keyboard.
            .pointerInput(Unit) { detectTapGestures { focus.clearFocus() } },
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(
            Modifier
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .widthIn(max = 780.dp)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 8.dp),
        ) {
            Header(model) { open = it }
            Spacer(Modifier.height(28.dp))
            TimerView(model, { clock.longValue }, { boil.longValue }, toggle) { palette.value = true }
            Spacer(Modifier.height(48.dp))
            YearView(model, filter, { filter = it }, picked, { picked = it })
        }
    }

    CommandPalette(
        palette.value,
        commands = {
            val sync = model.sync
            val tags = model.recentTags
            buildList {
                val title = when (model.status) {
                    is Status.Running -> "pause"
                    Status.Idle -> "start"
                    is Status.Paused -> "resume"
                }
                add(Command("toggle", title, "space", listOf("timer"), toggle))
                add(Command("skip", "skip", keywords = listOf("timer"), run = model::skip))
                if (model.isActive) add(Command("reset", if (model.isIntervals) "done" else "reset", keywords = listOf("timer"), run = model::reset))
                if (!model.isActive) {
                    add(Command("mode", "switch to ${Copy.modeName(!model.isIntervals)}", keywords = listOf("timer", "mode"), run = model::switchMode))
                }
                add(Command("settings", "open settings", keywords = listOf("preferences")) { open = Open.Settings })
                add(Command("inspo", "open inspo", keywords = listOf("videos")) { open = Open.Inspo })
                if (sync.isSignedIn) {
                    add(Command("sync", "sync now", run = sync::syncNow))
                    add(Command("auto", if (sync.auto) "turn auto sync off" else "turn auto sync on") { sync.updateAuto(!sync.auto) })
                }
                add(Command("today", "today", keywords = listOf("sessions")) { picked = model.today })
                tags.forEach { t -> add(Command("study:$t", "studying $t") { model.updateTag(t) }) }
                tags.forEach { t -> add(Command("show:$t", "show $t", keywords = listOf("filter")) { filter = t }) }
                add(Command("show all", "show all", keywords = listOf("filter")) { filter = null })
            }
        },
        fallback = { query ->
            val tag = query.trim()
            if (tag.isEmpty() || model.recentTags.any { it.equals(tag, ignoreCase = true) }) null
            else Command("new", "studying \"$tag\"") { model.updateTag(tag) }
        },
        close = { palette.value = false },
    )

    when (open) {
        Open.Settings -> SettingsSheet(model, close = { open = Open.None }, signIn = { open = Open.Account })
        Open.Account -> AccountSheet(model) { open = Open.None }
        Open.Inspo -> InspoSheet(model) { open = Open.None }
        Open.None -> Unit
    }
}

/** The links, on the right. When they don't fit, "update" becomes a badge on
 *  "settings"; past that, they wrap. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Header(model: AppModel, open: (Open) -> Unit) {
    val ink = LocalPalette.current
    val sync = model.sync
    val measurer = rememberTextMeasurer()
    val linkStyle = TextStyle(fontSize = 14.sp)
    val phone = LocalConfiguration.current.screenWidthDp < 600
    Row(verticalAlignment = Alignment.Top) {
        // Only while there's something to push.
        val word = if (sync.isSignedIn && sync.unpushed > 0 && sync.state != Sync.State.Syncing) {
            if (sync.state == Sync.State.Offline) "offline" else "sync"
        } else null
        // Offered only between blocks: installing restarts the app.
        val updater = model.updater
        val release = updater.available
        val downloading = updater.state is Updater.State.Downloading
        val update = when {
            downloading -> "updating…"
            release != null && !model.isActive -> if (phone) "update" else "update to ${release.version}"
            else -> null
        }
        BoxWithConstraints(Modifier.weight(1f)) {
            val gap = 16.dp
            val density = LocalDensity.current
            fun width(words: List<String>) = with(density) {
                words.sumOf { measurer.measure(it, linkStyle).size.width }.toDp() + gap * (words.size - 1)
            }
            val fixed = listOfNotNull(word, "inspo", "settings")
            val showUpdate = update != null && width(listOf(update) + fixed) <= maxWidth
            FlowRow(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(gap, Alignment.End),
            ) {
                model.lastError?.let {
                    Words(it, Modifier.align(Alignment.CenterVertically), size = 13.sp, color = ink.faint)
                }
                if (showUpdate) {
                    if (downloading) Words(update!!, Modifier.align(Alignment.CenterVertically), size = 14.sp, color = ink.faint)
                    else Link(update!!, compact = true, action = updater::install)
                }
                if (word != null) Link(word, compact = true, action = sync::syncNow)
                Link("inspo", compact = true) { open(Open.Inspo) }
                val badge = update != null && !showUpdate
                Link("settings", compact = true, badge = badge,
                    description = if (badge) "settings, update available" else null) { open(Open.Settings) }
            }
        }
    }
}
