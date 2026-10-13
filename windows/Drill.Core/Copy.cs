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

    public static (string Title, string Body) Finished(Phase finished, Phase next, double nextSeconds) =>
        finished == Phase.Focus
            ? ("focus done", $"take a break · {Amount(nextSeconds)}")
            : ("break's over", "back to it.");

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

    /// <summary>The tray's tooltip.</summary>
    public static string Tooltip(Phase phase, bool running, bool active, double remaining)
    {
        if (!active) return "drill";
        var clock = Clock(remaining);
        if (!running) return $"paused · {clock}";
        return $"{(phase.IsBreak() ? "break" : "focus")} · {clock} left";
    }
}
