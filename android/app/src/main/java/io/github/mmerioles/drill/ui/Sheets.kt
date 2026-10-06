package io.github.mmerioles.drill.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedContent
import kotlinx.coroutines.delay
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.ui.graphics.graphicsLayer
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
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.BuildConfig
import io.github.mmerioles.drill.Theme
import io.github.mmerioles.drill.core.Inspo
import io.github.mmerioles.drill.data.Sync
import io.github.mmerioles.drill.data.Updater
import io.github.mmerioles.drill.ink.LocalPalette
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
            val waiting = sync.waiting
            if (waiting != null) {
                SettingRow(waiting.email) {
                    StatusMark(if (waiting.confirmed) Mark.Done else Mark.Pending, breathing = true)
                    if (!waiting.confirmed) Link("cancel", action = sync::stopWaiting)
                }
            } else if (account == null) {
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
            val note = if (waiting != null) {
                if (waiting.confirmed) "you're in." else "check your inbox for the link."
            } else when (sync.state) {
                Sync.State.SignedOut -> "sign in to sync across devices."
                Sync.State.Syncing -> "syncing…"
                Sync.State.Idle -> "synced."
                Sync.State.Offline -> "offline. your sessions are safe here."
                Sync.State.Unconfirmed -> "confirm your email to start syncing."
            }
            Words(note, Modifier.padding(bottom = 12.dp), size = 13.sp, color = ink.faint)
        }

        val updater = model.updater
        LaunchedEffect(Unit) { updater.checkIfStale() }
        Row(Modifier.fillMaxWidth().padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Words("version ${BuildConfig.VERSION_NAME}", Modifier.weight(1f), size = 13.sp, color = ink.faint)
            UpdateMark(updater.state)
            Spacer(Modifier.width(8.dp))
            AnimatedContent(
                updater.state,
                transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(160)) },
                contentKey = { it::class },
                label = "update",
            ) { s ->
                when (s) {
                    Updater.State.Checking -> Words("checking…", size = 13.sp, color = ink.faint)
                    Updater.State.Downloading -> Words("downloading…", size = 13.sp, color = ink.faint)
                    is Updater.State.Available ->
                        Link("update to ${s.release.version}", size = 13.sp, on = true, action = updater::install)
                    is Updater.State.Failed -> Link(s.message, size = 13.sp) {
                        if (updater.available != null) updater.install() else scope.launch { updater.check(manual = true) }
                    }
                    Updater.State.UpToDate -> Link("up to date", size = 13.sp) { scope.launch { updater.check(manual = true) } }
                    Updater.State.Idle -> Link("check", size = 13.sp) { scope.launch { updater.check(manual = true) } }
                }
            }
        }
        Spacer(Modifier.height(18.dp))
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Capsule("done", small = true, action = close) }
    }
}

/** Sign in, or make an account: an email and a password, then a click on
 *  the link in the confirmation email, which the sheet notices by itself.
 *  Like AccountSheet.swift on the mac. */
@Composable
fun AccountSheet(model: AppModel, close: () -> Unit) {
    val ink = LocalPalette.current
    val sync = model.sync
    val scope = rememberCoroutineScope()
    var creating by remember { mutableStateOf(false) }
    var email by remember { mutableStateOf(sync.waiting?.email.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    var note by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val waiting = sync.waiting

    /** Runs one call at a time; a sentence that comes back is shown. */
    fun working(work: suspend () -> String?) {
        if (busy) return
        busy = true
        error = ""
        scope.launch {
            work()?.let { error = it }
            busy = false
        }
    }

    fun submit() {
        if (email.isBlank() || password.length < 8) {
            error = if (email.isBlank()) "enter your email." else "password needs 8+ characters."
            return
        }
        working {
            note = ""
            val problem = if (creating) sync.createAccount(email, password) else sync.signIn(email, password)
            if (problem == null && sync.waiting == null) close()
            problem
        }
    }

    fun resend() = working {
        val problem = sync.resendLink()
        if (problem == null) note = "sent another one."
        problem
    }

    // Once the link is clicked: a beat on the check mark, then out.
    LaunchedEffect(waiting?.confirmed) {
        if (waiting?.confirmed == true) {
            delay(1400)
            close()
        }
    }

    Sheet(close) {
        AnimatedContent(
            waiting != null,
            transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(160)) },
            label = "step",
        ) { linkStep ->
            Column {
                val w = sync.waiting
                if (!linkStep || w == null) {
                    Words(if (creating) "make an account" else "sign in", Modifier.padding(bottom = 14.dp),
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
                    if (error.isNotEmpty()) {
                        Words(error, Modifier.padding(bottom = 10.dp), size = 13.sp, color = ink.accent)
                    } else {
                        Words(if (creating) "password needs 8+ characters." else "",
                            Modifier.padding(bottom = 10.dp), size = 13.sp, color = ink.faint)
                    }
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Link(if (creating) "have an account?" else "new here?") { creating = !creating; error = "" }
                        Spacer(Modifier.weight(1f))
                        Capsule(if (creating) "create" else "sign in", small = true, enabled = !busy, action = ::submit)
                    }
                } else {
                    Row(Modifier.fillMaxWidth().padding(bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Crossfade(w.confirmed, Modifier.weight(1f), animationSpec = tween(220), label = "title") { done ->
                            Words(if (done) "you're in" else "check your inbox", size = 18.sp, weight = FontWeight.Bold)
                        }
                        StatusMark(if (w.confirmed) Mark.Done else Mark.Pending, breathing = true, size = 21.dp)
                    }
                    Crossfade(w.confirmed, animationSpec = tween(220), label = "note") { done ->
                        Words(
                            when {
                                done -> "syncing now."
                                note.isNotEmpty() -> note
                                else -> "tap the link we sent to ${w.email}."
                            },
                            Modifier.padding(bottom = 10.dp), size = 13.sp, color = ink.faint,
                        )
                    }
                    Words(error, Modifier.padding(bottom = 10.dp), size = 13.sp, color = ink.accent)
                    val links by animateFloatAsState(if (w.confirmed) 0f else 1f, tween(250), label = "links")
                    Row(Modifier.fillMaxWidth().graphicsLayer { alpha = links }, verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Link("wrong email?", size = 13.sp) { sync.stopWaiting(); error = "" }
                        Link("resend", size = 13.sp) { resend() }
                        Spacer(Modifier.weight(1f))
                        // Closing keeps waiting; settings shows how it's going.
                        Link("close", size = 13.sp, action = close)
                    }
                }
            }
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

/** How the last update check went: a spinner while looking, a green check
 *  when current, a yellow dot when there's something newer. */
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
