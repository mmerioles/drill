using System.Text.Json;
using Drill.Core.Inspo;
using Drill.Core.Model;
using Drill.Core.Store;
using Drill.Core.Timer;
using Drill.Core.Update;

namespace Drill.Core.Tests;

public class VersionTests
{
    [Fact]
    public void ParsesTagsAndCompares()
    {
        Assert.Equal(new AppVersion(1, 4, 2), AppVersion.Parse("v1.4.2"));
        Assert.Equal(new AppVersion(1, 4, 0), AppVersion.Parse("1.4"));
        Assert.Equal(new AppVersion(0, 9, 1), AppVersion.Parse("0.9.1+abc123"));
        Assert.Null(AppVersion.Parse("1.x"));
        Assert.Null(AppVersion.Parse("1.2.3.4"));
        Assert.Null(AppVersion.Parse("-1.2"));
        Assert.True(AppVersion.Parse("1.10.0") > AppVersion.Parse("1.9.9"));
    }
}

public class CopyTests
{
    [Fact]
    public void Clock()
    {
        Assert.Equal("25:00", Copy.Clock(1500));
        Assert.Equal("00:01", Copy.Clock(0.2));
        Assert.Equal("1:00:00", Copy.Clock(3600));
        Assert.Equal("00:00", Copy.Clock(0));
    }

    [Fact]
    public void Amounts()
    {
        Assert.Equal("0m", Copy.Amount(30));
        Assert.Equal("1h", Copy.Amount(3600));
        Assert.Equal("1h 15m", Copy.Amount(4500));
        Assert.Equal("1 day", Copy.Streak(1));
        Assert.Equal("13 days", Copy.Streak(13));
    }

    [Fact]
    public void Status()
    {
        Assert.Null(Copy.Status(Phase.Focus, running: false, active: false));
        Assert.Equal("paused", Copy.Status(Phase.Focus, running: false, active: true));
        Assert.Equal("focus", Copy.Status(Phase.Focus, running: true, active: true));
        Assert.Equal("long break", Copy.Status(Phase.LongBreak, running: false, active: false));
        Assert.Equal("sat, sep 26", Copy.Day(new DateTime(2026, 9, 26)));
    }

    [Fact]
    public void Finished()
    {
        Assert.Equal(("focus done", "take a break · 5 min"), Copy.Finished(Phase.Focus, Phase.ShortBreak, 300));
        Assert.Equal(("focus done", "take a break · 15 min"), Copy.Finished(Phase.Focus, Phase.LongBreak, 900));
        Assert.Equal(("break over", "back to focus"), Copy.Finished(Phase.ShortBreak, Phase.Focus, 1500));
        Assert.Equal(("break over", "back to focus"), Copy.Finished(Phase.LongBreak, Phase.Focus, 1500));
    }

    [Fact]
    public void Tooltip()
    {
        Assert.Equal("drill", Copy.Tooltip(Phase.Focus, running: false, active: false, 1500));
        Assert.Equal("focus · 12 min left", Copy.Tooltip(Phase.Focus, running: true, active: true, 11 * 60 + 1));
        Assert.Equal("focus · 12 min left", Copy.Tooltip(Phase.Focus, running: true, active: true, 12 * 60));
        Assert.Equal("break · 1 min left", Copy.Tooltip(Phase.ShortBreak, running: true, active: true, 20));
        Assert.Equal("paused · 3 min left", Copy.Tooltip(Phase.Focus, running: false, active: true, 150));
    }

    [Fact]
    public void Spoken()
    {
        Assert.Equal("focus, 12 minutes left", Copy.Spoken(Phase.Focus, running: true, active: true, 12 * 60));
        Assert.Equal("focus, 25 minutes left", Copy.Spoken(Phase.Focus, running: false, active: false, 1500));
        Assert.Equal("paused, 1 minute left", Copy.Spoken(Phase.Focus, running: false, active: true, 60));
        Assert.Equal("break, 30 seconds left", Copy.Spoken(Phase.ShortBreak, running: true, active: true, 30));
        Assert.Equal("your year. today 1h 15m, this week 5h, streak 13 days.", Copy.YearSummary(4500, 18000, 13));
    }
}

public class FocusSessionJsonTests
{
    [Fact]
    public void MatchesTheMacWireFormat()
    {
        var s = new FocusSession
        {
            Id = Guid.Parse("6f1c0a6e-3b8e-4c43-9a3d-1f0e2d3c4b5a"),
            StartedAt = DateTimeOffset.Parse("2026-09-26T13:00:00Z"),
            EndedAt = DateTimeOffset.Parse("2026-09-26T13:25:00.75Z"),
            FocusSeconds = 1500, PlannedSeconds = 1500, Completed = true, Tag = "15-213",
            DeviceID = "A1B2", UpdatedAt = DateTimeOffset.Parse("2026-09-26T09:25:00-04:00"),
        };
        var json = JsonSerializer.Serialize(s, FocusSession.Json);
        Assert.Equal(
            """{"id":"6F1C0A6E-3B8E-4C43-9A3D-1F0E2D3C4B5A","startedAt":"2026-09-26T13:00:00Z","endedAt":"2026-09-26T13:25:00Z","focusSeconds":1500,"plannedSeconds":1500,"completed":true,"tag":"15-213","deviceID":"A1B2","updatedAt":"2026-09-26T13:25:00Z","deletedAt":null}""",
            json);
        var back = JsonSerializer.Deserialize<FocusSession>(json, FocusSession.Json)!;
        Assert.Equal(s.Id, back.Id);
        Assert.Equal(s.UpdatedAt, back.UpdatedAt);
        Assert.Null(back.DeletedAt);
    }

    [Fact]
    public void ReadsFractionsAndOffsets()
    {
        var back = JsonSerializer.Deserialize<FocusSession>(
            """{"id":"6f1c0a6e-3b8e-4c43-9a3d-1f0e2d3c4b5a","startedAt":"2026-09-26T13:00:00.123+00:00","endedAt":"2026-09-26T13:25:00Z","focusSeconds":1500.5,"plannedSeconds":1500,"completed":false,"tag":null,"deviceID":"x","updatedAt":"2026-09-26T13:25:00Z","deletedAt":"2026-09-27T00:00:00Z"}""",
            FocusSession.Json)!;
        Assert.Equal(1500.5, back.FocusSeconds);
        Assert.Equal(DateTimeOffset.Parse("2026-09-27T00:00:00Z"), back.DeletedAt);
    }
}

public class InspoTests
{
    [Fact]
    public void LoadsTheSharedList()
    {
        Assert.True(InspoVideos.All.Count >= 37);
        Assert.Equal("KxGRhd_iWuE", InspoVideos.All[0].Youtube);
        Assert.Equal(1, InspoVideos.All[0].Number);
    }

    // Expected lists come from the shuffle in web/static/inspo.js.
    [Theory]
    [InlineData(20260928, "N4JV4wihKI4", "a568Txh1CJU", "FQMX48sgMMQ", "hySSRHwTiIM", "Yh-ctq-dS4s")]
    [InlineData(20261012, "6OFk3lhMhRQ", "-EBBTBqcA2U", "nzmzu7ofzCw", "aEQdesUJYY4", "eM6A8SjJQG0")]
    public void ShufflesLikeEveryOtherApp(int day, params string[] expected) =>
        Assert.Equal(expected, InspoVideos.ForToday(new HashSet<string>(), day).Select(v => v.Youtube));

    [Fact]
    public void LeavesOutWhatWasWatchedBefore()
    {
        var first = InspoVideos.ForToday(new HashSet<string>(), 20261012);
        var next = InspoVideos.ForToday(new HashSet<string> { first[0].Youtube }, 20261012);
        Assert.DoesNotContain(next, v => v.Youtube == first[0].Youtube);
        Assert.Equal(InspoVideos.PerDay, next.Count);
    }

    [Fact]
    public void WatchedPersists()
    {
        var prefs = Prefs.InMemory();
        var w = new Watched(prefs);
        w.Mark(InspoVideos.All[2]);
        Assert.True(new Watched(prefs).Contains(InspoVideos.All[2]));
        Assert.Equal(1, new Watched(prefs).Count);
    }
}

public class PrefsTests
{
    [Fact]
    public void SurvivesARestart()
    {
        var path = Path.Combine(Path.GetTempPath(), $"drill-prefs-{Guid.NewGuid()}.json");
        var p = new Prefs(path);
        p.Set("drill.theme", "light");
        p.Set("drill.config", new TimerConfig { Focus = 50 * 60 });
        var again = new Prefs(path);
        Assert.Equal("light", again.Get<string>("drill.theme"));
        Assert.Equal(50 * 60, again.Get<TimerConfig>("drill.config")?.Focus);
        Assert.Equal(DeviceIdentity.Current(again), DeviceIdentity.Current(new Prefs(path)));
        File.Delete(path);
    }

    [Fact]
    public void WrongShapesReadAsMissing()
    {
        var p = Prefs.InMemory();
        p.Set("drill.sound", "yes");
        Assert.Null(p.Get<bool?>("drill.sound"));
    }
}
