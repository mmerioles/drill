package io.github.mmerioles.drill.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.core.Inspo
import io.github.mmerioles.drill.ink.LocalPalette

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
        Spacer(Modifier.height(16.dp))
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
