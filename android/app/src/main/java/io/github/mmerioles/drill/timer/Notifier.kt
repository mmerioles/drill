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
import android.os.Build
import io.github.mmerioles.drill.R
import io.github.mmerioles.drill.DrillApp
import io.github.mmerioles.drill.core.Phase
import io.github.mmerioles.drill.ui.MainActivity

/**
 * The phone side of the timer. While a phase runs, an exact alarm waits for
 * its end and a quiet notification counts down. When the alarm fires, the
 * app catches up (AppModel.catchUp), which logs the block, says so, and
 * schedules the next phase if it auto-starts.
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

    /** Waits for the running phase to end, or stops waiting when [endsAt] is null. */
    fun schedule(context: Context, endsAt: Long?, phase: Phase) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val pending = PendingIntent.getBroadcast(
            context, 0, Intent(context, PhaseEndReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val nm = context.getSystemService(NotificationManager::class.java)
        if (endsAt == null) {
            alarms.cancel(pending)
            nm.cancel(RUNNING_ID)
            return
        }
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()
        if (exact) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endsAt, pending)
        else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endsAt, pending)

        if (!allowed(context)) return
        val title = if (phase == Phase.Focus) "focus" else if (phase == Phase.LongBreak) "long break" else "break"
        nm.notify(RUNNING_ID, Notification.Builder(context, TIMER)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setWhen(endsAt)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setChronometerCountDown(true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_STOPWATCH)
            .setContentIntent(openApp(context))
            .build())
    }

    /** Says a phase is over. */
    fun ended(context: Context, finished: Phase, sound: Boolean) {
        if (!allowed(context)) return
        val (title, body) = if (finished == Phase.Focus) "focus done" to "time for a break"
        else "break over" to "back to focus"
        context.getSystemService(NotificationManager::class.java).notify(ENDED_ID,
            Notification.Builder(context, if (sound) ENDS else ENDS_QUIET)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_ALARM)
                .setContentIntent(openApp(context))
                .build())
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
}

/** The running phase's alarm went off. */
class PhaseEndReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        DrillApp.model(context).catchUp()
    }
}

/** Alarms don't survive a restart; set the running phase's again. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        DrillApp.model(context).catchUp()
    }
}
