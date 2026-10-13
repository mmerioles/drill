using Drill.Core.Model;
using Drill.Core.Stats;
using Drill.Core.Store;

namespace Drill.Core.Tests;

public class SqliteSessionStoreTests
{
    private static FocusSession Session(long start, double minutes, string? tag = null, long? updated = null) => new()
    {
        StartedAt = DateTimeOffset.FromUnixTimeSeconds(start),
        EndedAt = DateTimeOffset.FromUnixTimeSeconds(start).AddMinutes(minutes),
        FocusSeconds = minutes * 60, PlannedSeconds = 25 * 60, Completed = true, Tag = tag, DeviceID = "test",
        UpdatedAt = DateTimeOffset.FromUnixTimeSeconds(updated ?? start),
    };

    [Fact]
    public void RoundTripsAndFiltersByRange()
    {
        using var store = SqliteSessionStore.InMemory();
        var a = Session(100, 25, "jp");
        var b = Session(5000, 10);
        store.Save(a);
        store.Save(b);
        Assert.Equal([a, b], store.Sessions(DateTimeOffset.MinValue, DateTimeOffset.MaxValue));
        Assert.Equal([b], store.Sessions(DateTimeOffset.FromUnixTimeSeconds(1000), DateTimeOffset.MaxValue));
    }

    [Fact]
    public void OlderWriteNeverOverwritesNewer()
    {
        using var store = SqliteSessionStore.InMemory();
        var s = Session(100, 25, updated: 200);
        store.Save(s);
        store.Save(s with { Tag = "stale", UpdatedAt = DateTimeOffset.FromUnixTimeSeconds(150) });
        Assert.Null(store.Sessions(DateTimeOffset.MinValue, DateTimeOffset.MaxValue)[0].Tag);

        store.Save(s with { Tag = "fresh", UpdatedAt = DateTimeOffset.FromUnixTimeSeconds(300) });
        Assert.Equal("fresh", store.Sessions(DateTimeOffset.MinValue, DateTimeOffset.MaxValue)[0].Tag);
    }

    [Fact]
    public void TombstonesHideButStillSync()
    {
        using var store = SqliteSessionStore.InMemory();
        var s = Session(100, 25);
        store.Save(s);
        var gone = DateTimeOffset.FromUnixTimeSeconds(400);
        store.Save(s with { DeletedAt = gone, UpdatedAt = gone });
        Assert.Empty(store.Sessions(DateTimeOffset.MinValue, DateTimeOffset.MaxValue));
        Assert.Equal([s.Id], store.Changes(DateTimeOffset.FromUnixTimeSeconds(300)).Select(c => c.Id));
    }

    [Fact]
    public void TagsAreMostRecentFirst()
    {
        using var store = SqliteSessionStore.InMemory();
        store.Save(Session(100, 5, "math"));
        store.Save(Session(200, 5, "jp"));
        store.Save(Session(300, 5));
        Assert.Equal(["jp", "math"], store.Tags(10));
    }

    [Fact]
    public void KeepsFileOnDisk()
    {
        var path = Path.Combine(Path.GetTempPath(), $"drill-test-{Guid.NewGuid()}", "drill.sqlite");
        var s = Session(100, 25, "jp");
        using (var store = new SqliteSessionStore(path)) store.Save(s);
        using (var again = new SqliteSessionStore(path))
            Assert.Equal([s], again.Sessions(DateTimeOffset.MinValue, DateTimeOffset.MaxValue));
        Directory.Delete(Path.GetDirectoryName(path)!, recursive: true);
    }
}

public class HeatmapBuilderTests
{
    private static readonly TimeZoneInfo NewYork = TimeZoneInfo.FindSystemTimeZoneById("America/New_York");
    private static readonly HeatmapBuilder Builder = new(DayOfWeek.Sunday, NewYork);

    private static DateTimeOffset At(int y, int m, int d, int h = 12)
    {
        var local = new DateTime(y, m, d, h, 0, 0, DateTimeKind.Unspecified);
        return new DateTimeOffset(local, NewYork.GetUtcOffset(local));
    }

    private static FocusSession Session(DateTimeOffset start, double minutes) => new()
    {
        StartedAt = start, EndedAt = start.AddMinutes(minutes), FocusSeconds = minutes * 60,
        PlannedSeconds = 1500, Completed = true, DeviceID = "t",
    };

    [Fact]
    public void LevelsUseFixedThresholds()
    {
        Assert.Equal(0, HeatmapBuilder.Level(0));
        Assert.Equal(1, HeatmapBuilder.Level(25 * 60));
        Assert.Equal(2, HeatmapBuilder.Level(60 * 60));
        Assert.Equal(3, HeatmapBuilder.Level(2 * 3600));
        Assert.Equal(4, HeatmapBuilder.Level(4 * 3600));
    }

    [Fact]
    public void GridEndsOnTodaysWeekAndHidesTheFuture()
    {
        var today = At(2026, 9, 26); // a Saturday — last row of its column
        var map = Builder.Build([Session(At(2026, 9, 26, 9), 50)], today);
        Assert.Equal(53, map.Weeks.Count);
        var lastDay = map.Weeks[^1][^1];
        Assert.Equal(new DateTime(2026, 9, 26), lastDay?.Date);
        Assert.Equal(2, lastDay?.Level);

        var midweek = Builder.Build([], At(2026, 9, 23));
        Assert.NotNull(midweek.Weeks[^1][3]);
        Assert.Null(midweek.Weeks[^1][4]);
    }

    [Fact]
    public void StreakSurvivesAnEmptyToday()
    {
        var sessions = new[] { At(2026, 9, 23), At(2026, 9, 24), At(2026, 9, 25) }.Select(d => Session(d, 25)).ToList();
        Assert.Equal(3, Builder.Build(sessions, At(2026, 9, 26)).Streak);
        Assert.Equal(0, Builder.Build(sessions, At(2026, 9, 27)).Streak);
    }

    [Fact]
    public void TotalsForTodayAndWeek()
    {
        var sessions = new[]
        {
            Session(At(2026, 9, 19), 60), // previous week
            Session(At(2026, 9, 21), 30),
            Session(At(2026, 9, 26, 8), 25),
            Session(At(2026, 9, 26, 15), 25),
        };
        var map = Builder.Build(sessions, At(2026, 9, 26, 20));
        Assert.Equal(50 * 60, map.Today);
        Assert.Equal(80 * 60, map.ThisWeek);
    }

    [Fact]
    public void LateNightCountsForThatLocalDay()
    {
        // 11:30pm in New York is the next day in UTC.
        var map = Builder.Build([Session(At(2026, 9, 25, 23), 25)], At(2026, 9, 26));
        Assert.Equal(new DateTime(2026, 9, 25), map.Weeks[^1][5]?.Date);
        Assert.Equal(1, map.Weeks[^1][5]?.Level);
    }

    [Fact]
    public void MondayFirstCultures()
    {
        var map = new HeatmapBuilder(DayOfWeek.Monday, NewYork).Build([], At(2026, 9, 26));
        Assert.Equal(DayOfWeek.Monday, map.Weeks[0][0]?.Date.DayOfWeek);
        Assert.Equal(new DateTime(2026, 9, 26), map.Weeks[^1][5]?.Date);
    }
}
