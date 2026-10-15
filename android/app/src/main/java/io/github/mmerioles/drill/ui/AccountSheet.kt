package io.github.mmerioles.drill.ui

import androidx.compose.foundation.layout.Box
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.data.Sync
import io.github.mmerioles.drill.core.Username
import io.github.mmerioles.drill.ink.LocalPalette
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What the live check knows about the username typed so far. */
private enum class Check { None, Checking, Available, Taken }

/** Sign in or make an account, with a username and a password. */
@Composable
fun AccountSheet(model: AppModel, close: () -> Unit) {
    val sheet = rememberSheet(close)
    var creating by rememberSaveable { mutableStateOf(false) }
    Sheet(sheet) {
        SheetTitle(if (creating) "create account" else "sign in")
        AccountForm(model.sync, creating, { creating = it }, Modifier.padding(top = 16.dp), cancel = { sheet.close() }) {
            sheet.close()
        }
    }
}

/** The fields and buttons of signing in or creating an account; the sheet and the welcome screen share it. */
@Composable
fun AccountForm(
    sync: Sync,
    creating: Boolean,
    switch: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    cancel: (() -> Unit)? = null,
    done: () -> Unit,
) {
    val ink = LocalPalette.current
    val scope = rememberCoroutineScope()
    // The passwords are never put in saved state.
    var username by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var check by remember { mutableStateOf(Check.None) }
    var stay by rememberSaveable { mutableStateOf(true) }

    val valid = Username.valid(username)

    // 300 ms after the last keystroke, ask; a new keystroke drops the old ask.
    LaunchedEffect(username, creating) {
        if (!creating || !valid) {
            check = Check.None
            return@LaunchedEffect
        }
        check = Check.Checking
        delay(300)
        check = when (sync.usernameAvailable(username)) {
            true -> Check.Available
            false -> Check.Taken
            null -> Check.None
        }
    }

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

    val mismatch = password.isNotEmpty() && confirm.isNotEmpty() && password != confirm
    val ready = if (creating) {
        check == Check.Available && password.length >= 8 && confirm == password
    } else {
        valid && password.isNotEmpty()
    }

    fun submit() {
        if (!ready) return
        working {
            val problem = if (creating) sync.createAccount(username, password, stay) else sync.signIn(username, password, stay)
            if (problem == null) done()
            problem
        }
    }

    Column(modifier) {
        Box(Modifier.fillMaxWidth()) {
            Field(username, { username = Username.clean(it); error = "" }, Modifier.fillMaxWidth().padding(end = if (creating) 24.dp else 0.dp),
                placeholder = "username", keyboard = KeyboardType.Ascii, weight = FontWeight.Normal, label = "username")
            if (creating) {
                StatusMark(
                    when (check) {
                        Check.Checking -> Mark.Working
                        Check.Available -> Mark.Done
                        Check.Taken -> Mark.Failed
                        Check.None -> Mark.None
                    },
                    Modifier.align(Alignment.CenterEnd).padding(bottom = 6.dp),
                )
            }
        }
        val hint = when {
            !creating || username.isEmpty() -> null
            !valid -> "3–20 letters, digits or _"
            check == Check.Taken -> "taken"
            else -> null
        }
        if (hint != null) Words(hint, Modifier.padding(top = 6.dp), size = 13.sp, color = ink.faint)
        Field(password, { password = it; error = "" }, Modifier.fillMaxWidth().padding(top = 24.dp),
            placeholder = "password", password = true, weight = FontWeight.Normal, label = "password",
            done = ::submit)
        if (creating) {
            Field(confirm, { confirm = it; error = "" }, Modifier.fillMaxWidth().padding(top = 24.dp),
                placeholder = "confirm password", password = true, weight = FontWeight.Normal, label = "confirm password", done = ::submit)
            if (mismatch) Words("passwords don't match", Modifier.padding(top = 6.dp), size = 13.sp, color = ink.faint)
        }
        Box(Modifier.padding(top = 12.dp)) { SwitchRow("stay signed in", stay) { stay = it } }
        if (error.isNotEmpty()) {
            Words(error, Modifier.padding(top = 10.dp), size = 13.sp, color = ink.accent)
        } else if (creating) {
            Words("password needs 8+ characters.", Modifier.padding(top = 10.dp), size = 13.sp, color = ink.faint)
        }
        Spacer(Modifier.height(24.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Link(if (creating) "have an account?" else "new here?") { switch(!creating); error = "" }
            Spacer(Modifier.weight(1f))
            if (cancel != null) {
                Link("cancel", action = cancel)
                Spacer(Modifier.width(8.dp))
            }
            Capsule(if (creating) "create account" else "sign in", small = true, enabled = ready && !busy, action = ::submit)
        }
    }
}
