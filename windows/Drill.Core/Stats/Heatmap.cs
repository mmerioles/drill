using System.Globalization;
using Drill.Core.Model;

namespace Drill.Core.Stats;

public sealed record HeatmapDay(DateTime Date, double Seconds, int Level);

/// <summary>A GitHub-style year of days, laid out in week columns.</summary>
/// <param name="Weeks">Weeks[column][row]; row 0 is the culture's first weekday.
/// Null marks days after today in the final column.</param>
/// <param name="Streak">Consecutive days with any focus, ending today (or
/// yesterday, so a streak is not "broken" before today's session).</param>
public sealed record Heatmap(IReadOnlyList<HeatmapDay?[]> Weeks, double Today, double ThisWeek, int Streak)
{
    public static readonly Heatmap Empty = new([], 0, 0, 0);
}

/// <summary>Days are local calendar days; dates here are local midnights.</summary>
public sealed class HeatmapBuilder(DayOfWeek? firstDayOfWeek = null, TimeZoneInfo? zone = null, int weeks = 53)
{
    private readonly DayOfWeek _first = firstDayOfWeek ?? CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek;
    private readonly TimeZoneInfo _zone = zone ?? TimeZoneInfo.Local;

    /// <summary>
    /// Intensity 0–4. Fixed thresholds rather than relative to your best day,
    /// so a cell means the same thing next year as it does today.
    /// </summary>
    public static int Level(double seconds) => seconds switch
    {
        < 60 => 0,
        < 30 * 60 => 1,
        < 90 * 60 => 2,
        < 180 * 60 => 3,
        _ => 4,
    };

    public DateTime Day(DateTimeOffset instant) => TimeZoneInfo.ConvertTime(instant, _zone).Date;

    /// <summary>The instants the grid covers — query the store with this.</summary>
    public (DateTimeOffset From, DateTimeOffset To) Range(DateTimeOffset today)
    {
        var from = StartOfWeek(Day(today)).AddDays(-7 * (weeks - 1));
        return (Instant(from), Instant(Day(today).AddDays(1)));
    }

    public Dictionary<DateTime, double> DailyTotals(IEnumerable<FocusSession> sessions)
    {
        var totals = new Dictionary<DateTime, double>();
        foreach (var s in sessions)
        {
            var day = Day(s.StartedAt);
            totals[day] = totals.GetValueOrDefault(day) + s.FocusSeconds;
        }
        return totals;
    }

    public Heatmap Build(IEnumerable<FocusSession> sessions, DateTimeOffset today)
    {
        var totals = DailyTotals(sessions);
        var todayStart = Day(today);
        var gridStart = StartOfWeek(todayStart).AddDays(-7 * (weeks - 1));

        var columns = new List<HeatmapDay?[]>(weeks);
        for (var w = 0; w < weeks; w++)
        {
            var column = new HeatmapDay?[7];
            for (var d = 0; d < 7; d++)
            {
                var date = gridStart.AddDays(w * 7 + d);
                if (date > todayStart) continue;
                var seconds = totals.GetValueOrDefault(date);
                column[d] = new HeatmapDay(date, seconds, Level(seconds));
            }
            columns.Add(column);
        }

        var weekStart = StartOfWeek(todayStart);
        var thisWeek = totals.Where(t => t.Key >= weekStart).Sum(t => t.Value);

        var streak = 0;
        var cursor = todayStart;
        if (totals.GetValueOrDefault(cursor) == 0) cursor = cursor.AddDays(-1);
        while (totals.GetValueOrDefault(cursor) > 0)
        {
            streak++;
            cursor = cursor.AddDays(-1);
        }

        return new Heatmap(columns, totals.GetValueOrDefault(todayStart), thisWeek, streak);
    }

    private DateTime StartOfWeek(DateTime day) => day.AddDays(-(((int)day.DayOfWeek - (int)_first + 7) % 7));

    /// <summary>A local midnight as an instant, across DST changes.</summary>
    private DateTimeOffset Instant(DateTime localDay)
    {
        var unspecified = DateTime.SpecifyKind(localDay, DateTimeKind.Unspecified);
        return new DateTimeOffset(unspecified, _zone.GetUtcOffset(unspecified));
    }
}
