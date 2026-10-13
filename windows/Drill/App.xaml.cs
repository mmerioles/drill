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
    private readonly Notifier _notifier = new();
    private bool _quitting;

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

        Native.SetAppId(Notifier.AppId);
        Model = AppModel.Live();
        Palette.Apply(Model.Theme, Resources);
        Sync = new Sync(Model.Store, Model.DeviceID, Model.Prefs, onPulled: Model.Reload);
        Model.OnLogged = Sync.SyncNow;
        Updater = new Updater();

        Model.Finished += Finished;
        Model.Ticked += ShowProgress;
        Model.PropertyChanged += (_, p) => { if (p.PropertyName == nameof(AppModel.Theme)) Retheme(); };
        _notifier.Acted += argument => Dispatcher.BeginInvoke(() => { if (argument == "start") Model.Start(); });

        _tray = new TrayIcon();
        _tray.Clicked += anchor => Pop(new TrayPanel(this, DismissPopup), anchor);
        _tray.MenuRequested += anchor => Pop(new TrayMenu(this, DismissPopup), anchor);

        Listen(ShowEvent, OpenMain);
        Listen(StartEvent, () => { Model.Start(); OpenMain(); });
        Listen(QuitEvent, Quit);
        SessionEnding += (_, _) => Quit(); // signing out or shutting down: never hide, just go

        Sync.Start();
        Updater.Start();
        SetJumpList();
        OpenMain();
        if (args.Contains("--start")) Model.Start();
        ShowProgress();
    }

    // Windows

    public void OpenMain()
    {
        if (_main is null)
        {
            _main = new InkWindow(new MainPage(this), "drill");
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
            window.Loaded += (_, _) => KeepOnScreen(window);
        }
        window.Closed += (_, _) => closed();
        return window;
    }

    private static void KeepOnScreen(Window w)
    {
        var work = SystemParameters.WorkArea;
        w.Left = Math.Clamp(w.Left, work.Left + 8, Math.Max(work.Left + 8, work.Right - w.ActualWidth - 8));
        w.Top = Math.Clamp(w.Top, work.Top + 8, Math.Max(work.Top + 8, work.Bottom - w.ActualHeight - 8));
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
        if (!Model.ToldAboutTray)
        {
            Model.ToldAboutTray = true;
            _notifier.Post("drill's still running", "find it in the tray, under ^ if it's hidden.");
        }
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

    private void Pop(FrameworkElement content, Native.RECT anchor)
    {
        DismissPopup();
        _popup = new PopupWindow(content);
        _popup.Closed += (_, _) => _popup = null;
        _popup.ShowNear(anchor);
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
        try
        {
            using var e = EventWaitHandle.OpenExisting(name);
            e.Set();
        }
        catch (WaitHandleCannotBeOpenedException) { } // it's on its way out
    }

    private void Listen(string name, Action act)
    {
        var e = new EventWaitHandle(false, EventResetMode.AutoReset, name);
        _waits.Add(ThreadPool.RegisterWaitForSingleObject(e, (_, _) => Dispatcher.BeginInvoke(act), null, Timeout.Infinite, executeOnlyOnce: false));
    }

    public void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        foreach (var w in _waits) w.Unregister(null);
        _popup?.Close();
        _tray?.Dispose();
        _tray = null;
        foreach (Window w in Windows) w.Close();
        // Let go of the mutex before leaving, so setup waiting on it can carry on at once.
        try { _mutex?.ReleaseMutex(); } catch (ApplicationException) { }
        _mutex?.Dispose();
        _mutex = null;
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
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
