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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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

/** Who you're syncing as, with a way in or out, like the mac's AccountRow. */
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

/** Our server by default; self-hosters put their own address here. Only
 *  while signed out: a token only works where it was made. */
@Composable
private fun ServerRow(sync: Sync) {
    val ink = LocalPalette.current
    var server by rememberSaveable { mutableStateOf(sync.customServer.orEmpty()) }
    var problem by remember { mutableStateOf<String?>(null) }
    // Leaving with an address typed but not entered still keeps it.
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

/** The version you're on, and one link that does the next sensible thing,
 *  like the mac's UpdateRow. Updating restarts the app, so not mid-block. */
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

/** Sign in, or make an account: an email and a password, then a click on
 *  the link in the confirmation email, which the sheet notices by itself.
 *  Like AccountSheet.swift on the mac. */
@Composable
fun AccountSheet(model: AppModel, close: () -> Unit) {
    val ink = LocalPalette.current
    val sync = model.sync
    val scope = rememberCoroutineScope()
    // Kept across a rotation or Android ending the process; the password
    // stays in memory only, never in saved state.
    var creating by rememberSaveable { mutableStateOf(false) }
    var email by rememberSaveable { mutableStateOf(sync.waiting?.email.orEmpty()) }
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

    val ready = email.contains("@") && password.length >= 8
    val sheet = rememberSheet(close)

    fun submit() {
        if (!ready) return
        working {
            note = ""
            val problem = if (creating) sync.createAccount(email, password) else sync.signIn(email, password)
            if (problem == null && sync.waiting == null) sheet.close()
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
            sheet.close()
        }
    }

    Sheet(sheet) {
        AnimatedContent(
            waiting != null,
            transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(160)) },
            label = "step",
        ) { linkStep ->
            Column {
                val w = sync.waiting
                if (!linkStep || w == null) {
                    SheetTitle(if (creating) "make an account" else "sign in", Modifier.padding(bottom = 8.dp))
                    // Stacked, full width, each named by its placeholder.
                    Field(email, { email = it; error = "" }, Modifier.fillMaxWidth().padding(top = 16.dp),
                        placeholder = "email", keyboard = KeyboardType.Email, weight = FontWeight.Normal, label = "email")
                    Field(password, { password = it; error = "" }, Modifier.fillMaxWidth().padding(top = 24.dp),
                        placeholder = "password", password = true, weight = FontWeight.Normal, label = "password", done = ::submit)
                    if (error.isNotEmpty()) {
                        Words(error, Modifier.padding(top = 10.dp), size = 13.sp, color = ink.accent)
                    } else if (creating) {
                        Words("password needs 8+ characters.", Modifier.padding(top = 10.dp), size = 13.sp, color = ink.faint)
                    }
                    Spacer(Modifier.height(24.dp))
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Link(if (creating) "have an account?" else "new here?", size = 13.sp) { creating = !creating; error = "" }
                        Spacer(Modifier.weight(1f))
                        Link("cancel", size = 13.sp) { sheet.close() }
                        Spacer(Modifier.width(8.dp))
                        Capsule(if (creating) "create" else "sign in", small = true, enabled = ready && !busy, action = ::submit)
                    }
                } else {
                    Row(Modifier.fillMaxWidth().padding(bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Crossfade(w.confirmed, Modifier.weight(1f), animationSpec = tween(220), label = "title") { done ->
                            SheetTitle(if (done) "you're in" else "check your inbox")
                        }
                        StatusMark(if (w.confirmed) Mark.Done else Mark.Pending, breathing = true, size = 21.dp)
                    }
                    Crossfade(w.confirmed, animationSpec = tween(220), label = "note") { done ->
                        Words(
                            when {
                                done -> "syncing now."
                                note.isNotEmpty() -> note
                                else -> "click the link we sent to ${w.email}."
                            },
                            Modifier.padding(bottom = 10.dp), size = 13.sp, color = ink.faint,
                        )
                    }
                    Words(error, Modifier.padding(bottom = 10.dp), size = 13.sp, color = ink.accent)
                    val links by animateFloatAsState(if (w.confirmed) 0f else 1f, tween(250), label = "links")
                    Row(Modifier.fillMaxWidth().graphicsLayer { alpha = links }, verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Link("wrong email?", size = 13.sp) { sync.stopWaiting(); error = "" }
                        Link("resend", size = 13.sp, enabled = !busy) { resend() }
                        Spacer(Modifier.weight(1f))
                        // Closing keeps waiting; settings shows how it's going.
                        Link("close", size = 13.sp) { sheet.close() }
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
    var all by rememberSaveable { mutableStateOf(false) }
    val seen = model.watched
    val today = remember { Inspo.day() }
    val list = if (all) Inspo.videos
    else remember(today) { Inspo.today(seen.filterValues { it < today }.keys) }

    fun watch(v: Inspo.Video) {
        model.markWatched(v)
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(v.url)))
    }

    Sheet(rememberSheet(close)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            SheetTitle("inspo", Modifier.weight(1f))
            Row(Modifier.selectableGroup(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Link("today", on = !all, selectable = true, compact = true) { all = false }
                Link("all", on = all, selectable = true, compact = true) { all = true }
            }
        }
        Spacer(Modifier.height(12.dp))
        if (all) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Inspo.videos.forEach { v ->
                    val watched = v.youtube in seen
                    Spacer(
                        Modifier.size(9.dp).clip(RoundedCornerShape(2.dp))
                            .background(if (watched) ink.accent.copy(alpha = 0.62f) else ink.wash)
                            .clickable(role = Role.Button) { watch(v) }
                            .semantics { contentDescription = "${v.number}. ${v.title}" + if (watched) ", watched" else "" },
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
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Words(v.title, Modifier.weight(1f, fill = false), size = 14.sp, weight = FontWeight.Medium)
                        if (v.youtube in seen) {
                            Spacer(Modifier.size(5.dp).background(ink.accent, CircleShape)
                                .semantics { contentDescription = "watched" })
                        }
                    }
                    Words(v.japanese, size = 13.sp, color = ink.faint)
                }
            }
        }
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
