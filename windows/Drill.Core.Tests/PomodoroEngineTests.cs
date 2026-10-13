using Drill.Core.Timer;

namespace Drill.Core.Tests;

public class PomodoroEngineTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_000_000);
    private static readonly TimerConfig Config = new()
    {
        Focus = 100, ShortBreak = 10, LongBreak = 30, LongBreakEvery = 2, AutoStartBreaks = true, AutoStartFocus = false,
    };

    private static DateTimeOffset At(double seconds) => T0.AddSeconds(seconds);

    [Fact]
    public void CountsDownFromWallClock()
    {
        var e = new PomodoroEngine(Config);
        e.Start(T0);
        Assert.Equal(60, e.Remaining(At(40)));
        Assert.Null(e.Tick(At(99)));
    }

    [Fact]
    public void PauseFreezesRemainingAndExcludesPausedTime()
    {
        var e = new PomodoroEngine(Config);
        e.Start(T0);
        e.Pause(At(30));
        Assert.Equal(70, e.Remaining(At(500)));
        e.Start(At(500));
        var t = e.Tick(At(570));
        Assert.NotNull(t);
        var r = t.Record!;
        Assert.Equal(100, r.FocusSeconds);
        Assert.Equal(T0, r.StartedAt);
        Assert.Equal(At(570), r.EndedAt);
        Assert.True(r.Completed);
    }

    [Fact]
    public void CompletedFocusAutoStartsBreakFromNow()
    {
        var e = new PomodoroEngine(Config);
        e.Start(T0);
        // Asleep well past the deadline: the break starts at wake, not at t0+100.
        var t = e.Tick(At(1000));
        Assert.Equal(Phase.ShortBreak, t?.Next);
        Assert.Equal(new PomodoroEngine.Status.Running(At(1010)), e.State);
        Assert.Null(e.Tick(At(1000)));
    }

    [Fact]
    public void EveryNthBreakIsLong()
    {
        var e = new PomodoroEngine(Config);
        e.Start(T0);
        Assert.Equal(Phase.ShortBreak, e.Tick(At(100))?.Next);
        Assert.Equal(Phase.Focus, e.Tick(At(110))?.Next);
        Assert.True(e.IsIdle); // AutoStartFocus is off
        e.Start(At(200));
        Assert.Equal(Phase.LongBreak, e.Tick(At(300))?.Next);
    }

    [Fact]
    public void SkippingFocusLogsPartialTimeOnlyAboveMinimum()
    {
        var e = new PomodoroEngine(new TimerConfig { Focus = 25 * 60 });
        e.Start(T0);
        Assert.Null(e.Skip(At(30)).Record);

        var f = new PomodoroEngine(new TimerConfig { Focus = 25 * 60 });
        f.Start(T0);
        var t = f.Skip(At(600));
        Assert.Equal(600, t.Record?.FocusSeconds);
        Assert.False(t.Record?.Completed);
        Assert.Equal(Phase.ShortBreak, t.Next);
        Assert.True(f.IsIdle); // skipped phases never auto-start
        Assert.Equal(1, f.FocusCount);
    }

    [Fact]
    public void SkippingFocusBuildsTowardsTheLongBreak()
    {
        var e = new PomodoroEngine(new TimerConfig { LongBreakEvery = 4 });
        var phases = Enumerable.Range(0, 8).Select(_ => e.Skip(T0).Next).ToList();
        Assert.Equal(
            [Phase.ShortBreak, Phase.Focus, Phase.ShortBreak, Phase.Focus,
             Phase.ShortBreak, Phase.Focus, Phase.LongBreak, Phase.Focus], phases);
        Assert.Equal(0, e.CyclePosition);
    }

    [Fact]
    public void ResetKeepsStudiedTimeAndRewinds()
    {
        var e = new PomodoroEngine(new TimerConfig { Focus = 25 * 60 });
        e.Start(T0);
        var r = e.Reset(At(300));
        Assert.Equal(300, r?.FocusSeconds);
        Assert.True(e.IsIdle);
        Assert.Equal(25 * 60, e.Remaining(At(300)));
        Assert.Equal(Phase.Focus, e.Phase);
    }

    [Fact]
    public void LongBreakEveryIsAtLeastOne() => Assert.Equal(1, new TimerConfig { LongBreakEvery = 0 }.LongBreakEvery);
}
