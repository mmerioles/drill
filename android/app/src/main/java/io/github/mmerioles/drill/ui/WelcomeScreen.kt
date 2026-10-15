package io.github.mmerioles.drill.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.ink.LocalPalette

/** Whenever nobody is signed in: sign in, or make an account. */
@Composable
fun WelcomeScreen(model: AppModel) {
    val ink = LocalPalette.current
    val focus = LocalFocusManager.current
    var creating by rememberSaveable { mutableStateOf(false) }
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(ink.paper)
            .pointerInput(Unit) { detectTapGestures { focus.clearFocus() } }
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        // Centred when it fits; scrolls when the keyboard leaves too little room.
        Box(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).heightIn(min = maxHeight),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                Modifier.widthIn(max = 400.dp).fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Words("drill", Modifier.semantics { heading() }, size = 34.sp, weight = FontWeight.SemiBold)
                Words("a quiet pomodoro timer", Modifier.padding(top = 6.dp), size = 15.sp, color = ink.faint)
                AccountForm(model.sync, creating, { creating = it }, Modifier.fillMaxWidth().padding(top = 40.dp)) {}
            }
        }
    }
}
