package io.github.mmerioles.drill.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.ink.LocalPalette
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Sign in or make an account; then waits for the email link to be clicked. */
@Composable
fun AccountSheet(model: AppModel, close: () -> Unit) {
    val ink = LocalPalette.current
    val sync = model.sync
    val scope = rememberCoroutineScope()
    // The password is never put in saved state.
    var creating by rememberSaveable { mutableStateOf(false) }
    var email by rememberSaveable { mutableStateOf(sync.waiting?.email.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    var note by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val waiting = sync.waiting

    /** One call at a time; a returned sentence is shown as the error. */
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
                        // Closing keeps waiting; settings shows progress.
                        Link("close", size = 13.sp) { sheet.close() }
                    }
                }
            }
        }
    }
}
