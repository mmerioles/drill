package io.github.mmerioles.tetodoro.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.tetodoro.AppModel
import io.github.mmerioles.tetodoro.BuildConfig
import io.github.mmerioles.tetodoro.Theme
import io.github.mmerioles.tetodoro.core.Inspo
import io.github.mmerioles.tetodoro.data.Sync
import io.github.mmerioles.tetodoro.data.Updater
import io.github.mmerioles.tetodoro.ink.LocalPalette
import kotlinx.coroutines.launch

@Composable
fun SettingsSheet(model: AppModel, close: () -> Unit, signIn: () -> Unit) {
    val ink = LocalPalette.current
    val c = model.config
    val sync = model.sync
    val scope = rememberCoroutineScope()

    Sheet(close) {
        Group {
            SettingRow("appearance") {
                Theme.entries.forEach { t ->
                    Link(t.name.lowercase(), on = model.theme == t) { model.updateTheme(t) }
                }
            }
        }
        Group {
            StepperRow("focus", c.focus / 60, 5..120, step = 5, unit = "min") { model.updateConfig(c.copy(focus = it * 60)) }
            StepperRow("short break", c.shortBreak / 60, 1..30, unit = "min") { model.updateConfig(c.copy(shortBreak = it * 60)) }
            StepperRow("long break", c.longBreak / 60, 5..60, step = 5, unit = "min") { model.updateConfig(c.copy(longBreak = it * 60)) }
            StepperRow("long break every", c.longBreakEvery, 2..8) { model.updateConfig(c.copy(longBreakEvery = it)) }
        }
        Group {
            SwitchRow("auto-start breaks", c.autoStartBreaks) { model.updateConfig(c.copy(autoStartBreaks = it)) }
            SwitchRow("auto-start focus", c.autoStartFocus) { model.updateConfig(c.copy(autoStartFocus = it)) }
            SwitchRow("sound", model.soundOn, model::updateSound)
        }
        Group {
            val account = sync.account
            if (account == null) {
                var server by remember { mutableStateOf(sync.customServer.orEmpty()) }
                var problem by remember { mutableStateOf<String?>(null) }
                SettingRow("server") {
                    Field(
                        server, { server = it; problem = null }, Modifier.width(170.dp),
                        placeholder = "ours", keyboard = KeyboardType.Uri, weight = FontWeight.Normal,
                        done = { problem = sync.setServer(server) },
                    )
                }
                problem?.let { Words(it, Modifier.padding(bottom = 10.dp), size = 13.sp, color = ink.accent) }
                SettingRow("sync") {
                    Link("sign in") {
                        problem = sync.setServer(server)
                        if (problem == null) signIn()
                    }
                }
            } else {
                SettingRow(account.email) { Link("sign out", action = sync::signOut) }
            }
            val note = when (sync.state) {
                Sync.State.SignedOut -> "sign in to keep your sessions on every device."
                Sync.State.Syncing -> "syncing…"
                Sync.State.Idle -> "synced."
                Sync.State.Offline -> "can't reach the server. sessions stay here until it's back."
                Sync.State.Unconfirmed -> "confirm your email to start syncing. check your inbox."
            }
            Words(note, Modifier.padding(bottom = 12.dp), size = 13.sp, color = ink.faint)
        }

        val updater = model.updater
        Row(Modifier.fillMaxWidth().padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Words("version ${BuildConfig.VERSION_NAME}", Modifier.weight(1f), size = 13.sp, color = ink.faint)
            when (val s = updater.state) {
                Updater.State.Checking -> Words("checking…", size = 13.sp, color = ink.faint)
                Updater.State.Downloading -> Words("downloading…", size = 13.sp, color = ink.faint)
                is Updater.State.Available ->
                    Link("update to ${s.release.version}", size = 13.sp, on = true, action = updater::install)
                is Updater.State.Failed -> Link(s.message, size = 13.sp) {
                    if (updater.available != null) updater.install() else scope.launch { updater.check() }
                }
                Updater.State.UpToDate -> Words("up to date", size = 13.sp, color = ink.faint)
                Updater.State.Idle -> Link("check", size = 13.sp) { scope.launch { updater.check() } }
            }
        }
        Spacer(Modifier.height(18.dp))
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Capsule("done", small = true, action = close) }
    }
}

@Composable
fun AccountSheet(model: AppModel, close: () -> Unit) {
    val ink = LocalPalette.current
    val scope = rememberCoroutineScope()
    var creating by remember { mutableStateOf(false) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }

    fun submit() {
        if (busy) return
        if (email.isBlank() || password.length < 8) {
            error = if (email.isBlank()) "enter your email." else "passwords are at least 8 characters."
            return
        }
        busy = true
        scope.launch {
            val problem = model.sync.signIn(email, password, creating)
            busy = false
            if (problem == null) close() else error = problem
        }
    }

    Sheet(close) {
        Words(if (creating) "create an account" else "sign in to sync", Modifier.padding(bottom = 14.dp),
            size = 18.sp, weight = FontWeight.Bold)
        Group {
            SettingRow("email") {
                Field(email, { email = it; error = "" }, Modifier.width(190.dp), keyboard = KeyboardType.Email,
                    weight = FontWeight.Normal)
            }
            SettingRow("password") {
                Field(password, { password = it; error = "" }, Modifier.width(190.dp), password = true,
                    weight = FontWeight.Normal, done = ::submit)
            }
        }
        Words(error, Modifier.padding(bottom = 10.dp), size = 13.sp, color = ink.accent)
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Link(if (creating) "i have an account" else "create an account") { creating = !creating; error = "" }
            Spacer(Modifier.weight(1f))
            Capsule(if (creating) "create" else "sign in", small = true, enabled = !busy, action = ::submit)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun InspoSheet(model: AppModel, close: () -> Unit) {
    val ink = LocalPalette.current
    val context = LocalContext.current
    var all by remember { mutableStateOf(false) }
    val seen = model.watched
    val today = remember { Inspo.day() }
    val list = if (all) Inspo.videos
    else remember(today) { Inspo.today(seen.filterValues { it < today }.keys) }

    fun watch(v: Inspo.Video) {
        model.markWatched(v)
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(v.url)))
    }

    Sheet(close) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Words("inspo", size = 18.sp, weight = FontWeight.Bold)
            Link("today", on = !all) { all = false }
            Link("all", on = all) { all = true }
        }
        Spacer(Modifier.height(12.dp))
        if (all) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Inspo.videos.forEach { v ->
                    Spacer(
                        Modifier.size(9.dp).clip(RoundedCornerShape(2.dp))
                            .background(if (v.youtube in seen) ink.accent.copy(alpha = 0.62f) else ink.wash)
                            .clickable(role = Role.Button) { watch(v) },
                    )
                }
            }
            Words("${seen.size} of ${Inspo.videos.size} watched", Modifier.padding(top = 8.dp, bottom = 12.dp),
                size = 12.sp, color = ink.faint)
        }
        list.forEach { v ->
            Row(
                Modifier.fillMaxWidth().clickable(role = Role.Button) { watch(v) }.padding(vertical = 9.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (all) Words("%03d".format(v.number), Modifier.widthIn(min = 28.dp), size = 12.sp, color = ink.faint)
                Column {
                    Words(v.title, weight = if (v.youtube in seen) FontWeight.Normal else FontWeight.SemiBold,
                        color = if (v.youtube in seen) ink.faint else ink.ink)
                    Words(v.japanese, size = 12.sp, color = ink.faint)
                }
            }
        }
        Spacer(Modifier.height(14.dp))
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Capsule("done", small = true, action = close) }
    }
}
