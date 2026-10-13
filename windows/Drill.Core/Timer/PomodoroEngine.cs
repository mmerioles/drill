namespace Drill.Core.Timer;

public enum Phase { Focus, ShortBreak, LongBreak }

public static class PhaseExtensions
{
    public static bool IsBreak(this Phase phase) => phase != Phase.Focus;
}

public sealed record TimerConfig
{
    public double Focus { get; init; } = 25 * 60;
    public double ShortBreak { get; init; } = 5 * 60;
    public double LongBreak { get; init; } = 15 * 60;
    /// <summary>A long break replaces every Nth short break.</summary>
    public int LongBreakEvery { get; init => field = Math.Max(1, value); } = 4;
    public bool AutoStartBreaks { get; init; } = true;
    public bool AutoStartFocus { get; init; }

    public static readonly TimerConfig Standard = new();

    public double Duration(Phase phase) => phase switch
    {
        Phase.Focus => Focus,
        Phase.ShortBreak => ShortBreak,
        _ => LongBreak,
    };
}

/// <summary>Focus time that should be written down, produced when a focus block ends.</summary>
public sealed record FocusRecord(
    DateTimeOffset StartedAt, DateTimeOffset EndedAt, double FocusSeconds, double PlannedSeconds, bool Completed);

/// <param name="Record">Present when the finished phase was focus and enough time was spent.</param>
/// <param name="Natural">True when the phase ran to zero rather than being skipped.</param>
public sealed record Transition(Phase Finished, Phase Next, FocusRecord? Record, bool Natural);

/// <summary>
/// The pomodoro state machine, ported from mac/Sources/DrillCore. Time is passed
/// in, so it never drifts, survives sleep, and is trivially testable. The
/// engine owns no clock: the host calls <see cref="Tick"/> as often as it
/// likes and gets back a <see cref="Transition"/> when a phase ends.
/// </summary>
public sealed class PomodoroEngine
{
    public abstract record Status
    {
        public sealed record Idle : Status;
        public sealed record Running(DateTimeOffset EndsAt) : Status;
        public sealed record Paused(double Remaining) : Status;
    }

    public TimerConfig Config { get; set; }
    public Phase Phase { get; private set; } = Phase.Focus;
    public Status State { get; private set; } = new Status.Idle();
    /// <summary>Focus blocks finished or skipped since launch; drives the long-break cadence.</summary>
    public int FocusCount { get; private set; }
    /// <summary>Cut-short focus blocks shorter than this are not worth logging.</summary>
    public double MinimumLoggable { get; set; } = 60;

    private DateTimeOffset? _blockStartedAt;
    private double _accrued;
    private DateTimeOffset? _runStartedAt;

    public PomodoroEngine(TimerConfig? config = null) => Config = config ?? TimerConfig.Standard;

    public bool IsRunning => State is Status.Running;
    public bool IsIdle => State is Status.Idle;
    public double Duration => Config.Duration(Phase);

    /// <summary>Position within the current long-break cycle, 0..&lt;LongBreakEvery.</summary>
    public int CyclePosition => FocusCount % Config.LongBreakEvery;

    public double Remaining(DateTimeOffset now) => State switch
    {
        Status.Paused p => p.Remaining,
        Status.Running r => Math.Max(0, (r.EndsAt - now).TotalSeconds),
        _ => Duration,
    };

    public double Progress(DateTimeOffset now) =>
        Duration <= 0 ? 0 : Math.Clamp(1 - Remaining(now) / Duration, 0, 1);

    // Controls

    public void Start(DateTimeOffset now)
    {
        switch (State)
        {
            case Status.Running:
                return;
            case Status.Paused p:
                Run(p.Remaining, now);
                break;
            default:
                _blockStartedAt = now;
                _accrued = 0;
                Run(Duration, now);
                break;
        }
    }

    public void Pause(DateTimeOffset now)
    {
        if (State is not Status.Running r) return;
        _accrued += (now - (_runStartedAt ?? now)).TotalSeconds;
        _runStartedAt = null;
        State = new Status.Paused(Math.Max(0, (r.EndsAt - now).TotalSeconds));
    }

    public void Toggle(DateTimeOffset now)
    {
        if (IsRunning) Pause(now); else Start(now);
    }

    /// <summary>Advances the clock. Returns a transition if the running phase hit zero.</summary>
    public Transition? Tick(DateTimeOffset now) =>
        State is Status.Running r && now >= r.EndsAt ? Finish(r.EndsAt, natural: true, now) : null;

    /// <summary>Ends the current phase early and moves to the next one, left idle.</summary>
    public Transition Skip(DateTimeOffset now) => Finish(now, natural: false, now);

    /// <summary>
    /// Abandons the current phase and rewinds it to full. Focus time already
    /// spent is still returned for logging — studying is studying.
    /// </summary>
    public FocusRecord? Reset(DateTimeOffset now)
    {
        var record = Phase == Phase.Focus ? MakeRecord(now, completed: false) : null;
        ClearBlock();
        return record;
    }

    // Internals

    private void Run(double seconds, DateTimeOffset now)
    {
        _runStartedAt = now;
        State = new Status.Running(now.AddSeconds(seconds));
    }

    private double Elapsed(DateTimeOffset time)
    {
        var live = _runStartedAt is { } started ? Math.Max(0, (time - started).TotalSeconds) : 0;
        return Math.Min(Duration, _accrued + live);
    }

    private FocusRecord? MakeRecord(DateTimeOffset endedAt, bool completed)
    {
        if (_blockStartedAt is not { } start) return null;
        var focused = Elapsed(endedAt);
        if (!completed && focused < MinimumLoggable) return null;
        return new FocusRecord(start, endedAt, focused, Config.Focus, completed);
    }

    private void ClearBlock()
    {
        _blockStartedAt = null;
        _runStartedAt = null;
        _accrued = 0;
        State = new Status.Idle();
    }

    private Transition Finish(DateTimeOffset endedAt, bool natural, DateTimeOffset now)
    {
        var finished = Phase;
        FocusRecord? record = null;

        if (finished == Phase.Focus)
        {
            record = MakeRecord(endedAt, completed: natural);
            // A skipped focus block still counts as a round, so skipping
            // keeps building towards the long break like any pomodoro timer.
            FocusCount++;
            Phase = FocusCount % Config.LongBreakEvery == 0 ? Phase.LongBreak : Phase.ShortBreak;
        }
        else
        {
            Phase = Phase.Focus;
        }
        ClearBlock();

        // Auto-started phases begin at `now`, not at the old deadline, so a
        // PC that slept through several phases wakes to one transition
        // instead of a chain of phantom sessions.
        var autoStart = Phase.IsBreak() ? Config.AutoStartBreaks : Config.AutoStartFocus;
        if (natural && autoStart) Start(now);

        return new Transition(finished, Phase, record, natural);
    }
}
