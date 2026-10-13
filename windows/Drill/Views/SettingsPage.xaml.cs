using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Drill.Core.Timer;
using Drill.Ink;
using Drill.Services;

namespace Drill.Views;

/// <summary>Settings: the same rows as the mac's, on cards.</summary>
public partial class SettingsPage : UserControl
{
    private readonly Shell _shell;
    private AppModel Model => _shell.Model;
    private bool _showing;
    private bool _listening;

    public SettingsPage(Shell shell)
    {
        _shell = shell;
        InitializeComponent();
        Appearance.Items = ["light", "dark"];

        Show();
        // The app's objects outlive this page: listen only while it's in a window.
        Loaded += (_, _) => Listen(true);
        Unloaded += (_, _) => Listen(false);
        IsVisibleChanged += (_, _) => { if (IsVisible) shell.Updater.CheckIfStale(); };

        Appearance.Changed += () =>
            Change(() => _shell.SetTheme(Appearance.SelectedIndex == 0 ? Theme.Light : Theme.Dark));
        Bind(FocusMinutes, c => c.Focus / 60, (c, v) => c with { Focus = v * 60 });
        Bind(ShortBreak, c => c.ShortBreak / 60, (c, v) => c with { ShortBreak = v * 60 });
        Bind(LongBreak, c => c.LongBreak / 60, (c, v) => c with { LongBreak = v * 60 });
        Bind(Every, c => c.LongBreakEvery, (c, v) => c with { LongBreakEvery = (int)v });
        Toggled(AutoBreaks, on => Model.Config = Model.Config with { AutoStartBreaks = on });
        Toggled(AutoFocus, on => Model.Config = Model.Config with { AutoStartFocus = on });
        Toggled(Sound, on => Model.SoundOn = on);
        Toggled(Tray, on => Model.KeepInTray = on);

        Server.TextChanged += (_, _) => ServerHint.Visibility = Server.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Server.KeyDown += (_, e) => { if (e.Key == Key.Enter) SaveServer(); };
        Server.LostKeyboardFocus += (_, _) => { SaveServer(); ServerLine.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Ghost"); };
        Server.GotKeyboardFocus += (_, _) => ServerLine.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Faint");
        Server.Text = shell.Sync.CustomServer ?? "";
        ShowAccount();
        ShowUpdate();
    }

    private void Listen(bool on)
    {
        if (on == _listening) return;
        _listening = on;
        if (on)
        {
            Model.PropertyChanged += OnModel;
            _shell.Sync.PropertyChanged += OnSync;
            _shell.Updater.PropertyChanged += OnUpdater;
            Show(); // whatever changed while away
            ShowAccount();
        }
        else
        {
            Model.PropertyChanged -= OnModel;
            _shell.Sync.PropertyChanged -= OnSync;
            _shell.Updater.PropertyChanged -= OnUpdater;
        }
    }

    /// <summary>Only what these rows show: not the clock's dozen changes a second.</summary>
    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppModel.Config) or nameof(AppModel.Theme) or nameof(AppModel.SoundOn) or nameof(AppModel.KeepInTray) or null or "":
                Show();
                break;
            case nameof(AppModel.IsActive):
                ShowUpdate();
                break;
        }
    }

    private void OnSync(object? sender, PropertyChangedEventArgs e) => ShowAccount();
    private void OnUpdater(object? sender, PropertyChangedEventArgs e) => ShowUpdate();

    /// <summary>Applies a change made here, ignoring the echo while the page is being filled in.</summary>
    private void Change(Action change)
    {
        if (!_showing) change();
    }

    private void Bind(Stepper stepper, Func<TimerConfig, double> get, Func<TimerConfig, double, TimerConfig> set) =>
        stepper.Changed += () => Change(() => Model.Config = set(Model.Config, stepper.Value));

    private void Toggled(Toggle toggle, Action<bool> set) =>
        toggle.Changed += () => Change(() => set(toggle.IsOn));

    private void Show()
    {
        _showing = true;
        var c = Model.Config;
        Appearance.SelectedIndex = Model.Theme == Theme.Light ? 0 : 1;
        FocusMinutes.Value = (int)(c.Focus / 60);
        ShortBreak.Value = (int)(c.ShortBreak / 60);
        LongBreak.Value = (int)(c.LongBreak / 60);
        Every.Value = c.LongBreakEvery;
        AutoBreaks.IsOn = c.AutoStartBreaks;
        AutoFocus.IsOn = c.AutoStartFocus;
        Sound.IsOn = Model.SoundOn;
        Tray.IsOn = Model.KeepInTray;
        _showing = false;
        ShowUpdate();
    }

    // Who you're syncing as, with a way in or out.

    private void ShowAccount()
    {
        var sync = _shell.Sync;
        AccountName.Text = sync.Account?.Email ?? sync.WaitingFor?.Email ?? "sync";
        AccountMark.Status = sync.WaitingFor is { } w ? (w.Confirmed ? StatusMark.Kind.Done : StatusMark.Kind.Pending) : StatusMark.Kind.None;
        AccountButton.Content = sync.WaitingFor is { Confirmed: false } ? "cancel" : sync.IsSignedIn ? "sign out" : "sign in";
        AccountNote.Text = sync.WaitingFor is { } waiting
            ? waiting.Confirmed ? "you're in." : "check your inbox for the link."
            : sync.State switch
            {
                SyncState.SignedOut => "sign in to sync across devices.",
                SyncState.Syncing => "syncing…",
                SyncState.Idle => "synced.",
                SyncState.Offline => "offline. your sessions are safe here.",
                _ => "confirm your email to start syncing.",
            };
        Server.IsEnabled = !sync.IsSignedIn;
        ServerNote.Text = sync.IsSignedIn ? "sign out to change servers." : "leave blank to use ours, or add your own.";
    }

    private void OnAccount(object sender, RoutedEventArgs e)
    {
        var sync = _shell.Sync;
        if (sync.WaitingFor is { Confirmed: false }) sync.StopWaiting();
        else if (sync.IsSignedIn) sync.SignOut();
        else _shell.ShowAccount(this);
    }

    private void SaveServer()
    {
        try
        {
            _shell.Sync.SetServer(Server.Text);
            Server.Text = _shell.Sync.CustomServer ?? "";
            ShowAccount();
        }
        catch (Sync.Problem p)
        {
            ServerNote.Text = p.Message;
        }
    }

    // The version you're on, and one button that does the next sensible thing.

    private void ShowUpdate()
    {
        var u = _shell.Updater;
        UpdateCard.Visibility = u.IsEnabled ? Visibility.Visible : Visibility.Collapsed;
        VersionLabel.Text = $"version {u.Current?.ToString() ?? "?"}";
        UpdateMark.Status = u.State switch
        {
            UpdateState.Checking or UpdateState.Installing => StatusMark.Kind.Working,
            UpdateState.UpToDate => StatusMark.Kind.Done,
            UpdateState.Available => StatusMark.Kind.Pending,
            _ => StatusMark.Kind.None,
        };
        UpdateNote.Text = u.State == UpdateState.Available && Model.IsActive
            ? "finish this block first. updating restarts the app."
            : u.Note;
        UpdateWorking.Text = u.State == UpdateState.Installing ? "updating…" : "checking…";
        UpdateWorking.Visibility = u.IsWorking ? Visibility.Visible : Visibility.Collapsed;
        UpdateButton.Visibility = u.IsWorking ? Visibility.Collapsed : Visibility.Visible;
        UpdateButton.Content = u.Available is { } r ? $"update to {r.Version}" : "check";
        UpdateButton.IsEnabled = !(u.State == UpdateState.Available && Model.IsActive);
    }

    private async void OnUpdate(object sender, RoutedEventArgs e)
    {
        var u = _shell.Updater;
        if (u.State == UpdateState.Available) await u.Install();
        else await u.Check();
    }
}
