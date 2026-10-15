package io.github.mmerioles.drill.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.BuildConfig
import io.github.mmerioles.drill.Theme
import io.github.mmerioles.drill.data.Sync
import io.github.mmerioles.drill.data.Updater
import io.github.mmerioles.drill.ink.LocalPalette
import kotlinx.coroutines.launch

@Composable
fun SettingsSheet(model: AppModel, close: () -> Unit, signIn: () -> Unit) {
    val ink = LocalPalette.current
    val c = model.config
    val sync = model.sync

    val sheet = rememberSheet(close)
    Sheet(sheet) {
        Group {
            SettingRow("appearance") {
                Segmented(Theme.entries, model.theme, { it.name.lowercase() }, model::updateTheme)
            }
        }
        Group {
            StepperRow("focus", c.focus / 60, 5..120, step = 5, unit = "min",
                less = "fewer focus minutes", more = "more focus minutes") { model.updateConfig(c.copy(focus = it * 60)) }
            StepperRow("short break", c.shortBreak / 60, 1..30, unit = "min",
                less = "fewer short break minutes", more = "more short break minutes") { model.updateConfig(c.copy(shortBreak = it * 60)) }
            StepperRow("long break", c.longBreak / 60, 5..60, step = 5, unit = "min",
                less = "fewer long break minutes", more = "more long break minutes") { model.updateConfig(c.copy(longBreak = it * 60)) }
            StepperRow("long break every", c.longBreakEvery, 2..8,
                less = "fewer blocks before a long break", more = "more blocks before a long break") { model.updateConfig(c.copy(longBreakEvery = it)) }
        }
        Group {
            SwitchRow("auto-start breaks", c.autoStartBreaks) { model.updateConfig(c.copy(autoStartBreaks = it)) }
            SwitchRow("auto-start focus", c.autoStartFocus) { model.updateConfig(c.copy(autoStartFocus = it)) }
            SwitchRow("sound", model.soundOn, model::updateSound)
        }
        Group {
            AccountRow(sync) { sheet.close(signIn) }
            ServerRow(sync)
        }
        Group { UpdateRow(model) }
    }
}

@Composable
private fun AccountRow(sync: Sync, signIn: () -> Unit) {
    val ink = LocalPalette.current
    val waiting = sync.waiting
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f)) {
            Words(sync.account?.email ?: waiting?.email ?: "sync")
            val note = if (waiting != null) {
                if (waiting.confirmed) "you're in." else "check your inbox for the link."
            } else when (sync.state) {
                Sync.State.SignedOut -> "sign in to sync across devices."
                Sync.State.Syncing -> "syncing…"
                Sync.State.Idle -> "synced."
                Sync.State.Offline -> "offline. your sessions are safe here."
                Sync.State.Unconfirmed -> "confirm your email to start syncing."
            }
            Words(note, size = 13.sp, color = ink.faint)
        }
        if (waiting != null) StatusMark(if (waiting.confirmed) Mark.Done else Mark.Pending, breathing = true)
        when {
            waiting?.confirmed == false -> Link("cancel", action = sync::stopWaiting)
            sync.isSignedIn -> Link("sign out", action = sync::signOut)
            else -> Link("sign in", primary = true, action = signIn)
        }
    }
}

/** A self-hosted server address; editable only while signed out. */
@Composable
private fun ServerRow(sync: Sync) {
    val ink = LocalPalette.current
    var server by rememberSaveable { mutableStateOf(sync.customServer.orEmpty()) }
    var problem by remember { mutableStateOf<String?>(null) }
    // Keep an address typed but not entered.
    DisposableEffect(Unit) { onDispose { if (!sync.isSignedIn) sync.setServer(server) } }
    Column(Modifier.padding(bottom = 10.dp)) {
        SettingRow("server") {
            Field(
                server, { server = it; problem = null }, Modifier.weight(1.3f).widthIn(max = 170.dp),
                placeholder = "drill's", keyboard = KeyboardType.Uri, weight = FontWeight.Normal,
                enabled = !sync.isSignedIn, label = "server",
                done = {
                    problem = sync.setServer(server)
                    if (problem == null) server = sync.customServer.orEmpty()
                },
            )
        }
        val note = problem ?: if (sync.isSignedIn) "sign out to change servers." else "leave blank to use ours, or add your own."
        Words(note, size = 13.sp, color = if (problem != null) ink.accent else ink.faint)
    }
}

/** The version, and one link for the next step. Updating restarts the app, so not mid-block. */
@Composable
private fun UpdateRow(model: AppModel) {
    val ink = LocalPalette.current
    val updater = model.updater
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { updater.checkIfStale() }
    val state = updater.state
    val note = when (state) {
        Updater.State.UpToDate -> "you're up to date."
        is Updater.State.Available ->
            if (model.isActive) "finish this block first. updating restarts the app." else "an update is available."
        is Updater.State.Failed -> state.message
        else -> null
    }
    Row(Modifier.fillMaxWidth().heightIn(min = 46.dp).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Words("version ${BuildConfig.VERSION_NAME}")
            AnimatedContent(note, transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(160)) }, label = "note") { n ->
                if (n != null) Words(n, size = 12.sp, color = ink.faint)
            }
        }
        UpdateMark(state)
        Spacer(Modifier.width(8.dp))
        AnimatedContent(
            state,
            transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(160)) },
            contentKey = { it::class },
            label = "update",
        ) { s ->
            when (s) {
                Updater.State.Checking -> Words("checking…", size = 13.sp, color = ink.faint)
                Updater.State.Downloading -> Words("updating…", size = 13.sp, color = ink.faint)
                is Updater.State.Available ->
                    Link("update to ${s.release.version}", size = 13.sp, on = !model.isActive,
                        enabled = !model.isActive, action = updater::install)
                is Updater.State.Failed -> Link(if (updater.available != null) "try again" else "check", size = 13.sp,
                    enabled = !(updater.available != null && model.isActive)) {
                    if (updater.available != null) updater.install() else scope.launch { updater.check(manual = true) }
                }
                else -> Link("check", size = 13.sp) { scope.launch { updater.check(manual = true) } }
            }
        }
    }
}

@Composable
private fun UpdateMark(state: Updater.State) {
    StatusMark(
        when (state) {
            Updater.State.Checking, Updater.State.Downloading -> Mark.Working
            Updater.State.UpToDate -> Mark.Done
            is Updater.State.Available -> Mark.Pending
            else -> Mark.None
        },
    )
}
