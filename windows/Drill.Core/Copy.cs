using System.Globalization;
using Drill.Core.Timer;

namespace Drill.Core;

/// <summary>Every user-facing sentence in one place. Lowercase, short, kind.</summary>
public static class Copy
{
    /// <summary>The word under the ring's top edge. Null when idle on focus — an idle timer needs no caption.</summary>
    public static string? Status(Phase phase, bool running, bool active) => (phase, active, running) switch
    {
        (Phase.Focus, false, _) => null,
        (_, true, false) => "paused",
        (Phase.Focus, _, _) => "focus",
        (Phase.ShortBreak, _, _) => "break",
        _ => "long break",
    };

    /// <summary>The toast when a phase runs out: "focus done" / "take a break · 5 min", or "break over" / "back to focus".</summary>
    public static (string Title, string Body) Finished(Phase finished, Phase next, double nextSeconds) =>
        finished == Phase.Focus
            ? ("focus done", $"take a break · {Math.Max(1, (int)Math.Round(nextSeconds / 60))} min")
            : ("break over", "back to focus");

    public static string Clock(double seconds)
    {
        var total = (int)Math.Ceiling(Math.Round(seconds, 6));
        int h = total / 3600, m = total % 3600 / 60, s = total % 60;
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m:00}:{s:00}";
    }

    public static string Amount(double seconds)
    {
        var minutes = (int)(seconds / 60);
        int h = minutes / 60, m = minutes % 60;
        return (h, m) switch
        {
            (0, _) => $"{m}m",
            (_, 0) => $"{h}h",
            _ => $"{h}h {m}m",
        };
    }

    public static string Streak(int days) => days == 1 ? "1 day" : $"{days} days";

    /// <summary>"sat, sep 26".</summary>
    public static string Day(DateTime date) =>
        date.ToString("ddd, MMM d", CultureInfo.InvariantCulture).ToLowerInvariant();

    public static string Month(DateTime date) =>
        date.ToString("MMM", CultureInfo.InvariantCulture).ToLowerInvariant();

    /// <summary>
    /// The tray's tooltip, to the minute ("focus · 12 min left"), so the
    /// icon is touched about once a minute rather than every second.
    /// </summary>
    public static string Tooltip(Phase phase, bool running, bool active, double remaining)
    {
        if (!active) return "drill";
        var left = $"{MinutesLeft(remaining)} min left";
        if (!running) return $"paused · {left}";
        return $"{(phase.IsBreak() ? "break" : "focus")} · {left}";
    }

    /// <summary>What a screen reader says for the timer: "focus, 12 minutes left".</summary>
    public static string Spoken(Phase phase, bool running, bool active, double remaining)
    {
        var what = Status(phase, running, active) ?? "focus";
        var seconds = (int)Math.Ceiling(Math.Round(remaining, 6));
        if (seconds < 60) return $"{what}, {seconds} {(seconds == 1 ? "second" : "seconds")} left";
        var minutes = MinutesLeft(remaining);
        return $"{what}, {minutes} {(minutes == 1 ? "minute" : "minutes")} left";
    }

    /// <summary>What a screen reader says for the year: "your year. today 1h 15m, this week 5h, streak 13 days."</summary>
    public static string YearSummary(double today, double week, int streak) =>
        $"your year. today {Amount(today)}, this week {Amount(week)}, streak {Streak(streak)}.";

    /// <summary>Whole minutes left, rounded up: 11:01 is "12".</summary>
    private static int MinutesLeft(double remaining) => (int)Math.Ceiling(Math.Round(remaining, 6) / 60);
}
