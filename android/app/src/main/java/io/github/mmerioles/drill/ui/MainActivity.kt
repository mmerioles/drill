package io.github.mmerioles.drill.ui

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color as AndroidColor
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.DrillApp
import io.github.mmerioles.drill.Theme
import io.github.mmerioles.drill.core.Status
import io.github.mmerioles.drill.data.Sync
import io.github.mmerioles.drill.data.Updater
import io.github.mmerioles.drill.ink.Doodle
import io.github.mmerioles.drill.ink.LocalPalette
import io.github.mmerioles.drill.ink.Palette
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    private val model by lazy { DrillApp.model(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        model.updater.start()
        setContent { App(model) }
    }

    override fun onResume() {
        super.onResume()
        model.catchUp()
        model.sync.syncNow()
        model.reload()
        model.updater.resume()
    }
}

enum class Open { None, Settings, Account, Inspo }

@Composable
fun App(model: AppModel) {
    val dark = when (model.theme) {
        Theme.Auto -> isSystemInDarkTheme()
        Theme.Light -> false
        Theme.Dark -> true
    }
    val activity = LocalContext.current as ComponentActivity
    SideEffect {
        val bars = if (dark) SystemBarStyle.dark(AndroidColor.TRANSPARENT)
        else SystemBarStyle.light(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT)
        activity.enableEdgeToEdge(bars, bars)
    }
    CompositionLocalProvider(LocalPalette provides if (dark) Palette.dark else Palette.light) {
        Screen(model)
    }
}

@Composable
fun Screen(model: AppModel) {
    val ink = LocalPalette.current
    val context = LocalContext.current
    var open by remember { mutableStateOf(Open.None) }

    // The clock: a quarter-second beat while running, enough for the digits
    // and the boil. When the phase runs out on screen, catch up at once
    // rather than waiting on the alarm.
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val running = model.timer.status as? Status.Running
    LaunchedEffect(running) {
        now = System.currentTimeMillis()
        while (running != null) {
            delay(250)
            now = System.currentTimeMillis()
            if (now >= running.endsAt) model.catchUp()
        }
    }
    // Catch up on other devices now and then while open.
    LaunchedEffect(Unit) {
        while (true) {
            delay(60_000)
            model.sync.syncNow()
            model.reload() // day rollover
        }
    }

    val still = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val tick = if (running != null && !still) now / Doodle.BOIL_MS else 0L

    // Once allowed, put up the countdown for the block that just started.
    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        model.catchUp()
    }
    val toggle = {
        if (model.timer.status is Status.Idle && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        model.toggle()
    }

    val focus = LocalFocusManager.current
    Box(
        Modifier
            .fillMaxSize()
            .background(ink.paper)
            // A tap outside the tag field puts it down, cursor and all.
            .pointerInput(Unit) { detectTapGestures { focus.clearFocus() } },
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(
            Modifier
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .widthIn(max = 780.dp)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 16.dp),
        ) {
            Header(model, tick) { open = it }
            Spacer(Modifier.height(36.dp))
            TimerView(model, now, tick, toggle)
            Spacer(Modifier.height(56.dp))
            YearView(model)
        }
    }

    when (open) {
        Open.Settings -> SettingsSheet(model, close = { open = Open.None }, signIn = { open = Open.Account })
        Open.Account -> AccountSheet(model) { open = Open.None }
        Open.Inspo -> InspoSheet(model) { open = Open.None }
        Open.None -> Unit
    }
}

@Composable
private fun Header(model: AppModel, tick: Long, open: (Open) -> Unit) {
    val sync = model.sync
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        DrillMark(tick)
        Words("drill", size = 20.sp, weight = FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        val word = if (sync.waiting?.confirmed == false) "check email" else when (sync.state) {
            Sync.State.SignedOut -> "sync"
            Sync.State.Syncing -> "syncing…"
            Sync.State.Offline -> "offline"
            Sync.State.Unconfirmed -> "confirm email"
            Sync.State.Idle -> if (sync.justSynced) "synced" else "sync"
        }
        // A newer version, offered between blocks: installing restarts the app.
        val updater = model.updater
        if (updater.state is Updater.State.Downloading) {
            Words("updating…", size = 14.sp, color = LocalPalette.current.faint)
            Spacer(Modifier.padding(start = 6.dp))
        } else if (updater.available != null && model.timer.status is Status.Idle) {
            Link("update", on = true, action = updater::install)
            Spacer(Modifier.padding(start = 6.dp))
        }
        Link(word) { if (sync.isSignedIn) sync.syncNow() else open(Open.Account) }
        Spacer(Modifier.padding(start = 6.dp))
        Link("inspo") { open(Open.Inspo) }
        Spacer(Modifier.padding(start = 6.dp))
        Link("settings") { open(Open.Settings) }
    }
}
