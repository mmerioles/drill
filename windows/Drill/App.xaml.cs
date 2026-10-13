using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using Drill.Core;
using Drill.Core.Inspo;
using Drill.Core.Timer;
using Drill.Ink;
using Drill.Services;
using Drill.Views;

namespace Drill;

/// <summary>What the pages need from the app: its state, and the ways around it.</summary>
public interface Shell
{
    AppModel Model { get; }
    Sync Sync { get; }
    Updater Updater { get; }
    void OpenMain();
    void OpenSettings();
    void OpenInspo();
    /// <summary>The sign-in dialog, over whichever window `from` is in.</summary>
    void ShowAccount(FrameworkElement from);
    void SetTheme(Theme theme);
    void Quit();
}

/// <summary>
/// drill for Windows: one process, one main window, a tray icon that keeps
/// the timer within reach after the window closes, the taskbar's progress
/// bar, and toasts when a phase ends.
/// </summary>
public partial class App : Application, Shell
{
    public const string MutexName = "drill-mmerioles-app";
    private const string ShowEvent = "drill-mmerioles-show";
    private const string StartEvent = "drill-mmerioles-start";
    /// <summary>Setup signals this to ask a running drill to quit (see windows/installer/drill.iss).</summary>
    private const string QuitEvent = "drill-mmerioles-quit";

    public static ImageSource? IconImage { get; private set; }

    public AppModel Model { get; private set; } = null!;
    public Sync Sync { get; private set; } = null!;
    public Updater Updater { get; private set; } = null!;

    private Mutex? _mutex;
    private readonly List<RegisteredWaitHandle> _waits = [];
    private TrayIcon? _tray;
    private InkWindow? _main;
    private InkWindow? _settings;
    private InkWindow? _inspo;
    private PopupWindow? _popup;
    /// <summary>When (and which kind of) flyout last lost focus: a click on the icon that dismissed it shouldn't reopen it.</summary>
    private (DateTime At, Type? Kind) _popupLost;
    private readonly Notifier _notifier = new();
    private bool _quitting;
    /// <summary>Signals from another launch that arrive before the model exists wait here.</summary>
    private List<Action>? _early = [];

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        IconImage = LoadIcon();

        var args = e.Args;
        if (args.Length >= 2 && args[0] == "--render")
        {
            Environment.ExitCode = Render.All(args[1]);
            Shutdown(Environment.ExitCode);
            return;
        }

        // One drill at a time: a second launch brings the first forward
        // (or starts it, from the jump list) and leaves.
        _mutex = new Mutex(initiallyOwned: true, MutexName, out var first);
        if (!first)
        {
            Signal(args.Contains("--start") ? StartEvent : ShowEvent);
            Shutdown();
            return;
        }

        // Listen at once, so a second launch in the next instant isn't lost;
        // whatever arrives before the model is ready runs once it is.
        Listen(ShowEvent, OpenMain);
        Listen(StartEvent, () => { Model.Start(); OpenMain(); });
        Listen(QuitEvent, Quit);

        Native.SetAppId(Notifier.AppId);
        Updater.SweepDownloads();
        Model = AppModel.Live();
        Palette.Apply(Model.Theme, Resources);
        Sync = new Sync(Model.Store, Model.DeviceID, Model.Prefs, onPulled: Model.Reload);
        Model.OnLogged = Sync.SyncNow;
        Updater = new Updater();

        Model.Finished += Finished;
        Model.Ticked += ShowProgress;
        Model.PropertyChanged += (_, p) => { if (p.PropertyName == nameof(AppModel.Theme)) Retheme(); };
        _notifier.Acted += argument => Dispatcher.BeginInvoke(() =>
        {
            if (_quitting) return;
            if (argument == "start") Model.Start();
            else if (argument == "open") OpenMain(); // the toast's body
        });

        _tray = new TrayIcon();
        _tray.Clicked += anchor => Pop(() => new TrayPanel(this, DismissPopup), anchor);
        _tray.MenuRequested += anchor => Pop(() => new TrayMenu(this, DismissPopup), anchor);

        SessionEnding += (_, _) => Quit(); // signing out or shutting down: never hide, just go

        Sync.Start();
        Updater.Start();
        SetJumpList();
        OpenMain();
        if (args.Contains("--start")) Model.Start();
        ShowProgress();

        var early = _early;
        _early = null;
        foreach (var act in early!) act();
    }

    // Windows

    public void OpenMain()
    {
        if (_main is null)
        {
            _main = new InkWindow(new MainPage(this), "drill", underCaption: true);
            _main.TaskbarItemInfo = new TaskbarItemInfo();
            _main.Closed += (_, _) => _main = null;
            ShowProgress();
        }
        _main.Present();
    }

    public void OpenSettings()
    {
        _settings ??= Opened(new InkWindow(new SettingsPage(this), "drill settings", minimizable: false), () => _settings = null);
        _settings.Present();
    }

    public void OpenInspo()
    {
        _inspo ??= Opened(new InkWindow(new InspoPage(new Watched(Model.Prefs)), "inspo", minimizable: false), () => _inspo = null);
        _inspo.Present();
    }

    private InkWindow Opened(InkWindow window, Action closed)
    {
        // Small windows open beside the main one when it's up, not over the timer.
        if (_main is { IsVisible: true, WindowState: WindowState.Normal } main)
        {
            window.WindowStartupLocation = WindowStartupLocation.Manual;
            window.Left = main.Left + main.ActualWidth - 120;
            window.Top = main.Top + 60;
            window.Loaded += (_, _) => KeepOnScreen(window, main);
        }
        window.Closed += (_, _) => closed();
        return window;
    }

    /// <summary>Inside the work area of the monitor `near` is on, in that monitor's pixels.</summary>
    private static void KeepOnScreen(Window w, Window near)
    {
        var hwnd = new System.Windows.Interop.WindowInteropHelper(w).Handle;
        var anchor = new System.Windows.Interop.WindowInteropHelper(near).Handle;
        if (hwnd == 0 || anchor == 0 || !Native.GetWindowRect(hwnd, out var r)) return;
        var (_, work, scale) = Native.MonitorOf(anchor);
        var margin = (int)Math.Round(8 * scale);
        var x = Math.Clamp(r.Left, work.Left + margin, Math.Max(work.Left + margin, work.Right - r.Width - margin));
        var y = Math.Clamp(r.Top, work.Top + margin, Math.Max(work.Top + margin, work.Bottom - r.Height - margin));
        if (x != r.Left || y != r.Top)
            Native.SetWindowPos(hwnd, 0, x, y, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
    }

    public void ShowAccount(FrameworkElement from)
    {
        var frame = FindFrame(from);
        if (frame is null) return;
        frame.Dialogs.Show(new AccountDialog(Sync, frame.Dialogs.Close));
    }

    private static InkFrame? FindFrame(DependencyObject? d)
    {
        while (d is not null and not InkFrame) d = VisualTreeHelper.GetParent(d) ?? LogicalTreeHelper.GetParent(d);
        return d as InkFrame;
    }

    /// <summary>Closing the main window keeps drill in the tray (once told), unless you'd rather it quit.</summary>
    internal void WindowClosing(InkWindow window, CancelEventArgs e)
    {
        if (window != _main || _quitting) return;
        if (!Model.KeepInTray)
        {
            Quit();
            return;
        }
        e.Cancel = true;
        window.Hide();
        if (!Model.ToldAboutTray && _notifier.Post("drill's still running", "find it in the tray, under ^ if it's hidden."))
            Model.ToldAboutTray = true;
    }

    public void SetTheme(Theme theme) => Model.Theme = theme;

    private void Retheme()
    {
        var frames = Windows.OfType<InkWindow>().Where(w => w.IsVisible).Select(w => w.Frame).ToList();
        void Apply() => Palette.Apply(Model.Theme, Resources);
        if (frames.Count == 0)
        {
            Apply();
            return;
        }
        // Every open window fades from a snapshot of its old look; the
        // palette changes once, under all of them.
        var applied = false;
        foreach (var f in frames) f.Crossfade(() => { if (!applied) { applied = true; Apply(); } });
    }

    // Tray

    /// <summary>
    /// Opens a flyout by the icon, or, as Windows 11's own do, closes it when
    /// the icon is clicked again. That click usually reaches us after the
    /// flyout has already lost focus to the taskbar, so a click just after
    /// that counts as the closing one.
    /// </summary>
    private void Pop<T>(Func<T> make, Native.RECT anchor) where T : FrameworkElement
    {
        if (_quitting) return;
        if (_popup is { IsDismissing: false } open)
        {
            var same = open.Content is T;
            open.Dismiss();
            if (same) return;
        }
        else if (_popupLost.Kind == typeof(T) && DateTime.UtcNow - _popupLost.At < TimeSpan.FromMilliseconds(300))
        {
            return;
        }
        var p = new PopupWindow(make());
        p.Deactivated += (_, _) => _popupLost = (DateTime.UtcNow, typeof(T));
        p.Closed += (_, _) => { if (_popup == p) _popup = null; };
        _popup = p;
        p.ShowNear(anchor);
    }

    private void DismissPopup() => _popup?.Dismiss();

    /// <summary>The tray icon, its tooltip, and the taskbar button's progress bar.</summary>
    private void ShowProgress()
    {
        _tray?.Update(Model.IsActive, Model.Progress, Model.IsPaused, Model.Tooltip);
        if (_main?.TaskbarItemInfo is { } bar)
        {
            bar.ProgressState = !Model.IsActive ? TaskbarItemProgressState.None
                : Model.IsRunning ? TaskbarItemProgressState.Normal : TaskbarItemProgressState.Paused;
            bar.ProgressValue = Model.Progress;
            bar.Description = Model.Tooltip;
        }
    }

    private static void SetJumpList()
    {
        var list = new JumpList();
        list.JumpItems.Add(new JumpTask
        {
            Title = "start focus",
            Arguments = "--start",
            ApplicationPath = Environment.ProcessPath,
            IconResourcePath = Environment.ProcessPath,
        });
        list.ShowFrequentCategory = false;
        list.ShowRecentCategory = false;
        JumpList.SetJumpList(Current, list);
    }

    // A phase ran out

    private void Finished(Transition t)
    {
        var copy = Copy.Finished(t.Finished, t.Next, Model.Config.Duration(t.Next));
        // When the next phase waits for you, the toast can start it.
        var waits = !Model.IsRunning;
        (string, string)? action = waits ? (t.Next.IsBreak() ? "start break" : "start focus", "start") : null;
        _notifier.Post(copy.Title, copy.Body, action);
        if (Model.SoundOn)
        {
            if (t.Finished == Phase.Focus) Chime.FocusDone(); else Chime.BreakOver();
        }
    }

    // One instance

    private static void Signal(string name)
    {
        // The running drill may have just taken the mutex and not yet made
        // its events: give it a moment.
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                using var e = EventWaitHandle.OpenExisting(name);
                // We were just launched, so we may hand the foreground on; it couldn't take it itself.
                Native.AllowSetForegroundWindow(Native.ASFW_ANY);
                e.Set();
                return;
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                Thread.Sleep(50); // starting up, or on its way out
            }
        }
    }

    private void Listen(string name, Action act)
    {
        var e = new EventWaitHandle(false, EventResetMode.AutoReset, name);
        _waits.Add(ThreadPool.RegisterWaitForSingleObject(e, (_, _) => Dispatcher.BeginInvoke(() =>
        {
            if (_quitting) return;
            if (_early is { } early) early.Add(act);
            else act();
        }), null, Timeout.Infinite, executeOnlyOnce: false));
    }

    public void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        foreach (var w in _waits) w.Unregister(null);
        // Quitting mid-focus keeps the focus so far, as reset does.
        if (Model is { IsActive: true } model)
        {
            model.OnLogged = null; // no sync starting on the way out
            model.Reset();
        }
        _popup?.Close();
        _tray?.Dispose();
        _tray = null;
        foreach (Window w in Windows) w.Close();
        Shutdown();
    }

    /// <summary>
    /// After every window has closed: the database is closed, then the
    /// mutex let go, so setup waiting on it finds drill's files free.
    /// </summary>
    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _tray = null;
        (Model?.Store as IDisposable)?.Dispose();
        try { _mutex?.ReleaseMutex(); } catch (ApplicationException) { } // a second launch never owned it
        _mutex?.Dispose();
        _mutex = null;
        base.OnExit(e);
    }

    private static ImageSource? LoadIcon()
    {
        try
        {
            var decoder = BitmapDecoder.Create(new Uri("pack://application:,,,/Assets/drill.ico"), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            return decoder.Frames.OrderByDescending(f => f.PixelWidth).FirstOrDefault(f => f.PixelWidth <= 64) ?? decoder.Frames[0];
        }
        catch (Exception)
        {
            return null;
        }
    }
}
