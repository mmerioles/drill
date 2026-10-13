using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Threading;
using Drill.Core;
using Drill.Core.Model;
using Drill.Core.Stats;
using Drill.Core.Store;
using Drill.Core.Timer;
using Drill.Ink;
using Microsoft.Win32;

namespace Drill.Services;

/// <summary>INotifyPropertyChanged with less typing.</summary>
public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    /// <summary>Everything changed: views re-read every binding.</summary>
    protected void RaiseAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }
}

/// <summary>
/// The app's single source of truth, as in Sources/DrillApp/AppModel.swift:
/// owns the engine, drives its clock, writes finished focus blocks to the
/// store, and keeps the heatmap fresh. Views bind to it and call its
/// intents; nothing else touches the store.
/// </summary>
public sealed class AppModel : Observable
{
    public PomodoroEngine Engine { get; }
    public ISessionStore Store { get; }
    public string DeviceID { get; }
    public Prefs Prefs { get; }

    /// <summary>Called after a finished block is written, so sync can send it along.</summary>
    public Action? OnLogged { get; set; }
    /// <summary>A phase ran to zero by itself: for the toast and the chime.</summary>
    public event Action<Transition>? Finished;
    /// <summary>The clock moved: once per second while running, and on every intent.</summary>
    public event Action? Ticked;

    private readonly Func<DateTimeOffset> _clock;
    private readonly DispatcherTimer _tick;
    private readonly DispatcherTimer _midnight;
    private readonly HeatmapBuilder _builder = new();
    private string? _blockTag;
    private IReadOnlyList<FocusSession> _yearSessions = [];

    public AppModel(ISessionStore store, Prefs prefs, TimerConfig? configOverride = null, Func<DateTimeOffset>? clock = null)
    {
        Store = store;
        Prefs = prefs;
        _clock = clock ?? (() => DateTimeOffset.Now);
        DeviceID = DeviceIdentity.Current(prefs);
        Engine = new PomodoroEngine(configOverride ?? prefs.Get<TimerConfig>(Keys.Config) ?? TimerConfig.Standard);
        _tag = prefs.Get<string>(Keys.Tag) ?? "";
        _soundOn = prefs.Get<bool?>(Keys.Sound) ?? true;
        _keepInTray = prefs.Get<bool?>(Keys.Tray) ?? true;
        _theme = prefs.Get<string>(Keys.Theme) == "light" ? Theme.Light : Theme.Dark;
        Now = _clock();

        _tick = new DispatcherTimer(DispatcherPriority.Send);
        _tick.Tick += (_, _) => Tick();
        _midnight = new DispatcherTimer(DispatcherPriority.Background);
        _midnight.Tick += (_, _) => Reload();
        ScheduleMidnight();

        // A PC that slept wakes to the right time at once, not on the next tick.
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.Resume) _tick.Dispatcher.BeginInvoke(() => { Tick(); Reload(); });
        };
        SystemEvents.TimeChanged += (_, _) => _tick.Dispatcher.BeginInvoke(Reload);

        Reload();
    }

    /// <summary>
    /// Production wiring. DRILL_DB points at another database file,
    /// DRILL_FAST=1 shrinks minutes to seconds, and DRILL_THEME (light|dark)
    /// overrides the saved theme — all for trying things out.
    /// </summary>
    public static AppModel Live()
    {
        var path = Environment.GetEnvironmentVariable("DRILL_DB") is { Length: > 0 } db ? db : SqliteSessionStore.DefaultPath;
        ISessionStore store;
        try { store = new SqliteSessionStore(path); }
        catch (Exception) { store = SqliteSessionStore.InMemory(); } // keep the timer usable even if the disk isn't
        var fast = Environment.GetEnvironmentVariable("DRILL_FAST") == "1"
            ? new TimerConfig { Focus = 20, ShortBreak = 5, LongBreak = 10 } : null;
        var model = new AppModel(store, Prefs.Standard(), fast);
        switch (Environment.GetEnvironmentVariable("DRILL_THEME"))
        {
            case "light": model.Theme = Theme.Light; break;
            case "dark": model.Theme = Theme.Dark; break;
        }
        return model;
    }

    // State

    /// <summary>Wall clock as of the last tick; views derive countdowns from it.</summary>
    public DateTimeOffset Now { get; private set; }

    public Heatmap Heatmap { get; private set => Set(ref field, value); } = Heatmap.Empty;
    public IReadOnlyList<string> RecentTags { get; private set => Set(ref field, value); } = [];
    public string? LastError { get; private set => Set(ref field, value); }

    private string _tag;
    /// <summary>What you're studying. Captured when a focus block starts.</summary>
    public string Tag
    {
        get => _tag;
        set
        {
            if (!Set(ref _tag, value)) return;
            Prefs.Set(Keys.Tag, value);
            Raise(nameof(Suggestions));
        }
    }

    /// <summary>Recent tags to tap, leaving out the one already typed.</summary>
    public IReadOnlyList<string> Suggestions =>
        RecentTags.Where(t => t != Tag.Trim().ToLowerInvariant()).Take(4).ToList();

    private string? _tagFilter;
    /// <summary>Null shows every session.</summary>
    public string? TagFilter
    {
        get => _tagFilter;
        set
        {
            if (Set(ref _tagFilter, value)) RebuildHeatmap();
        }
    }

    public TimerConfig Config
    {
        get => Engine.Config;
        set
        {
            if (Engine.Config == value) return;
            Engine.Config = value;
            Prefs.Set(Keys.Config, value);
            Raise();
            RaiseClock();
        }
    }

    private bool _soundOn;
    public bool SoundOn
    {
        get => _soundOn;
        set { if (Set(ref _soundOn, value)) Prefs.Set(Keys.Sound, value); }
    }

    private bool _keepInTray;
    /// <summary>Closing the window leaves drill running in the tray.</summary>
    public bool KeepInTray
    {
        get => _keepInTray;
        set { if (Set(ref _keepInTray, value)) Prefs.Set(Keys.Tray, value); }
    }

    private Theme _theme;
    public Theme Theme
    {
        get => _theme;
        set { if (Set(ref _theme, value)) Prefs.Set(Keys.Theme, value == Theme.Light ? "light" : "dark"); }
    }

    /// <summary>Whether the tray hint toast has been shown, so it shows once.</summary>
    public bool ToldAboutTray
    {
        get => Prefs.Get<bool?>(Keys.ToldTray) ?? false;
        set => Prefs.Set(Keys.ToldTray, value);
    }

    // Derived

    public double Remaining => Engine.Remaining(Now);
    public double Progress => Engine.Progress(Now);
    public Phase Phase => Engine.Phase;
    public bool IsRunning => Engine.IsRunning;
    public bool IsActive => !Engine.IsIdle;
    public bool IsPaused => IsActive && !IsRunning;
    public string Clock => Copy.Clock(Remaining);
    public string? Status => Copy.Status(Phase, IsRunning, IsActive);
    public string PrimaryLabel => IsRunning ? "pause" : IsActive ? "resume" : "start";
    public int CyclePosition => Engine.CyclePosition;
    public int CycleLength => Config.LongBreakEvery;
    public string Tooltip => Copy.Tooltip(Phase, IsRunning, IsActive, Remaining);

    // Intents

    public void Toggle()
    {
        var starting = Engine.IsIdle;
        Now = _clock();
        Engine.Toggle(Now);
        if (starting && Engine.Phase == Phase.Focus) CaptureTag();
        SyncTicking();
        RaiseClock();
    }

    /// <summary>Starts unless already running: the jump list's "start focus".</summary>
    public void Start()
    {
        if (!IsRunning) Toggle();
    }

    public void Skip()
    {
        Now = _clock();
        Handle(Engine.Skip(Now));
        SyncTicking();
        RaiseClock();
    }

    public void Reset()
    {
        Now = _clock();
        if (Engine.Reset(Now) is { } record) Log(record);
        SyncTicking();
        RaiseClock();
    }

    /// <summary>Re-reads the clock now: for --render, whose clock is a fixed moment.</summary>
    internal void Refresh()
    {
        Now = _clock();
        RaiseClock();
    }

    // Clock

    /// <summary>
    /// Wakes exactly when the displayed second changes (plus a hair), rather
    /// than polling: one wake a second, never a skipped or doubled digit,
    /// and no drift over a long block.
    /// </summary>
    private void SyncTicking()
    {
        if (!Engine.IsRunning)
        {
            _tick.Stop();
            return;
        }
        var remaining = Engine.Remaining(_clock());
        var untilNextSecond = remaining - Math.Floor(remaining - 1e-6);
        _tick.Interval = TimeSpan.FromSeconds(Math.Clamp(untilNextSecond, 0.001, 1) + 0.004);
        _tick.Start();
    }

    private void Tick()
    {
        Now = _clock();
        if (Engine.Tick(Now) is { } transition) Handle(transition);
        SyncTicking();
        RaiseClock();
    }

    private void RaiseClock()
    {
        Raise(nameof(Remaining));
        Raise(nameof(Progress));
        Raise(nameof(Phase));
        Raise(nameof(IsRunning));
        Raise(nameof(IsActive));
        Raise(nameof(IsPaused));
        Raise(nameof(Clock));
        Raise(nameof(Status));
        Raise(nameof(PrimaryLabel));
        Raise(nameof(CyclePosition));
        Raise(nameof(CycleLength));
        Raise(nameof(Tooltip));
        Ticked?.Invoke();
    }

    private void Handle(Transition t)
    {
        if (t.Record is { } record) Log(record);
        if (t.Next == Phase.Focus && Engine.IsRunning) CaptureTag();
        if (t.Natural) Finished?.Invoke(t);
    }

    // Data

    private void CaptureTag()
    {
        var trimmed = Tag.Trim().ToLowerInvariant();
        _blockTag = trimmed.Length == 0 ? null : trimmed;
    }

    private void Log(FocusRecord r)
    {
        var session = new FocusSession
        {
            StartedAt = r.StartedAt, EndedAt = r.EndedAt, FocusSeconds = r.FocusSeconds,
            PlannedSeconds = r.PlannedSeconds, Completed = r.Completed, Tag = _blockTag,
            DeviceID = DeviceID, UpdatedAt = DateTimeOffset.UtcNow,
        };
        try
        {
            Store.Save(session);
            LastError = null;
            OnLogged?.Invoke();
        }
        catch (Exception)
        {
            LastError = "couldn't save that session.";
        }
        Reload();
    }

    public void Reload()
    {
        var range = _builder.Range(_clock());
        try { _yearSessions = Store.Sessions(range.From, range.To); } catch (Exception) { _yearSessions = []; }
        try { RecentTags = Store.Tags(6); } catch (Exception) { RecentTags = []; }
        Raise(nameof(Suggestions));
        if (TagFilter is { } filter && !RecentTags.Contains(filter)) TagFilter = null;
        RebuildHeatmap();
        ScheduleMidnight();
    }

    private void RebuildHeatmap()
    {
        var shown = TagFilter is { } t ? _yearSessions.Where(s => s.Tag == t) : _yearSessions;
        Heatmap = _builder.Build(shown, _clock());
    }

    /// <summary>The grid moves on a day at midnight.</summary>
    private void ScheduleMidnight()
    {
        var now = DateTime.Now;
        _midnight.Interval = now.Date.AddDays(1) - now + TimeSpan.FromSeconds(1);
        _midnight.Start();
    }

    private static class Keys
    {
        public const string Config = "drill.config";
        public const string Tag = "drill.tag";
        public const string Sound = "drill.sound";
        public const string Theme = "drill.theme";
        public const string Tray = "drill.keepInTray";
        public const string ToldTray = "drill.toldAboutTray";
    }
}
