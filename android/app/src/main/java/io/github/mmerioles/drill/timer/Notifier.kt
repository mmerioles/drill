package io.github.mmerioles.drill.timer

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.github.mmerioles.drill.AppModel
import io.github.mmerioles.drill.DrillApp
import io.github.mmerioles.drill.R
import io.github.mmerioles.drill.core.Copy
import io.github.mmerioles.drill.core.IntervalPhase
import io.github.mmerioles.drill.core.Phase
import io.github.mmerioles.drill.core.Status
import io.github.mmerioles.drill.ui.MainActivity
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The phone side of the timer: an exact alarm for the end of the running
 * phase, a countdown notification with pause/skip/reset, and the "phase
 * over" notification. The alarm calls AppModel.catchUp.
 */
object Notifier {
    private const val TIMER = "timer"
    private const val ENDS = "ends"
    private const val ENDS_QUIET = "ends-quiet"
    private const val RUNNING_ID = 1
    private const val ENDED_ID = 2

    fun setUp(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannels(listOf(
            NotificationChannel(TIMER, "timer", NotificationManager.IMPORTANCE_LOW).apply {
                description = "the countdown while a phase runs"
                setShowBadge(false)
            },
            NotificationChannel(ENDS, "phase ends", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "when focus or a break is over"
            },
            NotificationChannel(ENDS_QUIET, "phase ends, silent", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "when focus or a break is over, with sound off"
                setSound(null, null)
                enableVibration(false)
            },
        ))
    }

    /** What the countdown last showed, so a swiped-away paused notification isn't reposted. */
    private var posted: Any? = null

    /** Sets the alarm and countdown for [status]; clears both when idle. [name]
     *  is "focus · maths" or "run · round 3"; [stop] names the last button. */
    fun schedule(context: Context, status: Status, name: String, remaining: Long, stop: String = "reset") {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val pending = PendingIntent.getBroadcast(
            context, 0, Intent(context, PhaseEndReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val nm = context.getSystemService(NotificationManager::class.java)
        if (status !is Status.Running) alarms.cancel(pending)
        if (status is Status.Idle) {
            nm.cancel(RUNNING_ID)
            posted = null
            return
        }
        if (status is Status.Running) {
            val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()
            if (exact) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, status.endsAt, pending)
            else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, status.endsAt, pending)
        }

        if (!allowed(context)) return
        val shows = listOf(status, name, stop)
        if (shows == posted) return
        val builder = Notification.Builder(context, TIMER)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(name)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_STOPWATCH)
            .setContentIntent(openApp(context))
        if (status is Status.Running) {
            builder
                .setWhen(status.endsAt)
                .setShowWhen(true)
                .setUsesChronometer(true)
                .setChronometerCountDown(true)
                .setOngoing(true)
                // Gone at zero, rather than counting below it if the alarm runs late.
                .setTimeoutAfter(maxOf(1, remaining))
                .addAction(action(context, "pause", TimerActionReceiver.TOGGLE))
        } else {
            builder
                .setContentText("paused · ${Copy.clock(remaining)}")
                .setShowWhen(false)
                .setOngoing(false)
                .addAction(action(context, "resume", TimerActionReceiver.TOGGLE))
        }
        builder
            .addAction(action(context, "skip", TimerActionReceiver.SKIP))
            .addAction(action(context, stop, TimerActionReceiver.RESET))
        nm.notify(RUNNING_ID, builder.build())
        posted = shows
    }

    /** "focus done · take a break · 5 min", with a start button when the next phase [waits]. */
    fun ended(context: Context, finished: Phase, next: Phase, nextSeconds: Int, waits: Boolean, sound: Boolean) {
        val (title, body) = Copy.finished(finished, nextSeconds)
        ended(context, title, body, sound, offered = next.takeIf { waits })
    }

    /** The chime is the channel's sound, so this is the cue for any phase ending. */
    fun ended(context: Context, title: String, body: String, sound: Boolean, offered: Phase? = null) {
        if (!allowed(context)) return
        val builder = Notification.Builder(context, if (sound) ENDS else ENDS_QUIET)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_ALARM)
            .setContentIntent(openApp(context))
        if (offered != null) builder.addAction(action(context, Copy.startNext(offered), TimerActionReceiver.START, offered = offered))
        context.getSystemService(NotificationManager::class.java).notify(ENDED_ID, builder.build())
    }

    /** Two long pulses into a run, one short into a walk. Straight to the
     *  vibrator: the channels keep vibration off, and this must work with
     *  the screen off. */
    fun vibrate(context: Context, phase: IntervalPhase) {
        val pattern = if (phase == IntervalPhase.Run) longArrayOf(0, 400, 150, 400) else longArrayOf(0, 250)
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        }
        if (!vibrator.hasVibrator()) return
        val effect = VibrationEffect.createWaveform(pattern, -1)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            vibrator.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(effect, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
        }
    }

    fun clearEnded(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(ENDED_ID)
    }

    private fun allowed(context: Context) =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun openApp(context: Context) = PendingIntent.getActivity(
        context, 0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun action(context: Context, title: String, what: String, offered: Phase? = null): Notification.Action {
        val intent = Intent(context, TimerActionReceiver::class.java).setAction(what)
        offered?.let { intent.putExtra(TimerActionReceiver.OFFERED, it.name) }
        val pending = PendingIntent.getBroadcast(
            context, what.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Action.Builder(Icon.createWithResource(context, R.drawable.ic_notification), title, pending).build()
    }
}

/** Runs [work], then keeps the process alive until its writes and sync finish (up to 9s). */
private fun BroadcastReceiver.withModel(context: Context, work: (AppModel) -> Unit) {
    val result = goAsync()
    val model = DrillApp.model(context)
    work(model)
    model.scope.launch {
        try {
            withTimeoutOrNull(9_000L) { model.settle() }
        } finally {
            result.finish()
        }
    }
}

class PhaseEndReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = withModel(context) { it.catchUp() }
}

class TimerActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = withModel(context) { model ->
        model.catchUp()
        when (intent.action) {
            TOGGLE -> model.toggle()
            SKIP -> model.skip()
            RESET -> model.reset()
            START -> intent.getStringExtra(OFFERED)
                ?.let { runCatching { Phase.valueOf(it) }.getOrNull() }
                ?.let(model::startNext)
        }
    }

    companion object {
        const val TOGGLE = "io.github.mmerioles.drill.TOGGLE"
        const val SKIP = "io.github.mmerioles.drill.SKIP"
        const val RESET = "io.github.mmerioles.drill.RESET"
        const val START = "io.github.mmerioles.drill.START"
        const val OFFERED = "offered"
    }
}

/** Alarms don't survive a reboot or update; set it again. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        DrillApp.model(context).catchUp()
    }
}
