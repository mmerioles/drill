using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Drill.Core.Inspo;
using Drill.Core.Model;
using Drill.Core.Store;
using Drill.Core.Timer;
using Drill.Core.Update;
using Drill.Ink;
using Drill.Services;
using Drill.Views;

namespace Drill;

/// <summary>
/// `Drill.exe --render &lt;dir&gt;`: every screen, in both themes, drawn to PNGs at
/// 2x without opening a window — the app's real XAML and drawing code on a
/// made-up year of study. CI runs it so the Windows app can be looked at
/// from anywhere.
/// </summary>
internal static class Render
{
    private static readonly DateTimeOffset Moment = new(2026, 10, 12, 15, 0, 0, TimeZoneInfo.Local.GetUtcOffset(new DateTime(2026, 10, 12, 15, 0, 0)));

    public static int All(string folder)
    {
        Directory.CreateDirectory(folder);
        Motion.Disable();
        var failures = 0;
        void Shot(string name, Func<FrameworkElement> make)
        {
            try
            {
                Save(make(), Path.Combine(folder, name + ".png"));
                Console.WriteLine($"rendered {name}");
            }
            catch (Exception e)
            {
                failures++;
                Console.Error.WriteLine($"couldn't render {name}: {e}");
            }
        }

        foreach (var theme in new[] { Theme.Light, Theme.Dark })
        {
            var t = theme == Theme.Light ? "light" : "dark";
            Shot($"main-{t}-idle", () => MainScreen(theme, running: false, paused: false));
            Shot($"main-{t}-running", () => MainScreen(theme, running: true, paused: false));
            Shot($"main-{t}-paused", () => MainScreen(theme, running: true, paused: true));
            Shot($"settings-{t}", () =>
            {
                var shell = new Demo(theme);
                shell.Updater.Pretend(new AppVersion(1, 4, 0), theme == Theme.Light ? UpdateState.Available : UpdateState.UpToDate,
                                      theme == Theme.Light ? new AppVersion(1, 5, 0) : null);
                return new InkFrame(new SettingsPage(shell), minimizable: false);
            });
            Shot($"account-{t}", () =>
            {
                var shell = new Demo(theme);
                var frame = new InkFrame(new MainPage(shell), underCaption: true);
                frame.Dialogs.Show(new AccountDialog(shell.Sync, () => { }));
                return frame;
            });
            Shot($"account-{t}-waiting", () =>
            {
                var shell = new Demo(theme);
                shell.Sync.PretendWaiting("teto@example.com");
                var frame = new InkFrame(new MainPage(shell), underCaption: true);
                frame.Dialogs.Show(new AccountDialog(shell.Sync, () => { }));
                return frame;
            });
            Shot($"inspo-{t}-today", () => { _ = new Demo(theme); return new InkFrame(new InspoPage(Watched()), minimizable: false); });
            Shot($"inspo-{t}-all", () =>
            {
                _ = new Demo(theme);
                var page = new InspoPage(Watched());
                page.ShowAll();
                return new InkFrame(page, minimizable: false);
            });
            Shot($"tray-{t}", () =>
            {
                var shell = new Demo(theme);
                Run(shell, paused: false);
                return Popup(new TrayPanel(shell, () => { }));
            });
            Shot($"traymenu-{t}", () =>
            {
                var shell = new Demo(theme);
                Run(shell, paused: false);
                return Popup(new TrayMenu(shell, () => { }));
            });
        }
        Shot("tray-icons", TrayIcons);
        return failures == 0 ? 0 : 1;
    }

    private static FrameworkElement MainScreen(Theme theme, bool running, bool paused)
    {
        var shell = new Demo(theme);
        if (running) Run(shell, paused);
        return new InkFrame(new MainPage(shell), underCaption: true);
    }

    /// <summary>Fourteen and a bit minutes into a focus block on "15-213".</summary>
    private static void Run(Demo shell, bool paused)
    {
        shell.Model.Tag = "15-213";
        shell.Model.Toggle();
        shell.Now = Moment.AddSeconds(14 * 60 + 23);
        if (paused) shell.Model.Toggle();
        shell.Model.Refresh();
    }

    private static Watched Watched()
    {
        var prefs = Prefs.InMemory();
        var w = new Watched(prefs);
        foreach (var v in InspoVideos.All.Where((_, i) => i % 3 == 0)) w.Mark(v);
        return w;
    }

    /// <summary>A tray popup as Windows shows it: paper, a hairline, rounded corners.</summary>
    private static FrameworkElement Popup(FrameworkElement content)
    {
        var border = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Child = content, Margin = new Thickness(24) };
        border.SetResourceReference(Border.BackgroundProperty, "Paper");
        border.SetResourceReference(Border.BorderBrushProperty, "Border");
        TextOptions.SetTextRenderingMode(border, TextRenderingMode.Grayscale);
        var desk = new Grid { Background = new SolidColorBrush(Palette.Current.Theme == Theme.Dark ? Color.FromRgb(0x20, 0x26, 0x30) : Color.FromRgb(0xC9, 0xD4, 0xE2)) };
        desk.Children.Add(border);
        return desk;
    }

    /// <summary>The tray icon in every state and size, on both taskbars, drawn 1:1 and then at 6×.</summary>
    private static FrameworkElement TrayIcons()
    {
        var sizes = new[] { 16, 20, 24, 32 };
        var states = new (bool Live, double Progress, bool Paused)[] { (false, 0, false), (true, 0.08, false), (true, 0.45, false), (true, 0.82, false), (true, 0.45, true) };
        var rows = new StackPanel();
        foreach (var light in new[] { false, true })
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Background = new SolidColorBrush(light ? Color.FromRgb(0xEE, 0xEE, 0xEE) : Color.FromRgb(0x1C, 0x1C, 0x1C)) };
            foreach (var size in sizes)
            foreach (var s in states)
            {
                var image = TrayIcon.Picture(size, s.Live, s.Progress, s.Paused, light);
                var big = new Image { Source = image, Width = size * 6, Height = size * 6, Margin = new Thickness(8), Stretch = Stretch.Fill };
                RenderOptions.SetBitmapScalingMode(big, BitmapScalingMode.NearestNeighbor);
                row.Children.Add(big);
            }
            rows.Children.Add(row);
        }
        return rows;
    }

    /// <summary>Lays `element` out in a hidden window (so it loads like the real thing) and saves it at 2×.</summary>
    private static void Save(FrameworkElement element, string path)
    {
        using var host = new HwndSource(new HwndSourceParameters("drill render") { Width = 1, Height = 1, WindowStyle = unchecked((int)0x80000000) });
        host.RootVisual = element;
        for (var i = 0; i < 3; i++)
        {
            element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            element.Arrange(new Rect(element.DesiredSize));
            element.UpdateLayout();
            Application.Current.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.ContextIdle);
        }
        var size = element.DesiredSize;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(size.Width * 2), (int)Math.Ceiling(size.Height * 2), 192, 192, PixelFormats.Pbgra32);
        bitmap.Render(element);
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path);
        png.Save(file);
        host.RootVisual = null;
    }

    /// <summary>The app's pieces over an in-memory year of made-up study, frozen at one moment.</summary>
    private sealed class Demo : Shell
    {
        public DateTimeOffset Now = Moment;
        public AppModel Model { get; }
        public Sync Sync { get; }
        public Updater Updater { get; } = new();

        public Demo(Theme theme)
        {
            var store = SqliteSessionStore.InMemory();
            Fill(store);
            var prefs = Prefs.InMemory();
            Model = new AppModel(store, prefs, clock: () => Now) { Theme = theme };
            Palette.Apply(theme, Application.Current.Resources);
            Sync = new Sync(store, Model.DeviceID, prefs, () => { });
        }

        /// <summary>A year like the mac screenshots': busier lately, three subjects, a 13-day streak.</summary>
        private void Fill(ISessionStore store)
        {
            var rng = new Random(7);
            string[] tags = ["piano", "jp", "15-213"];
            var today = Moment.Date;
            for (var back = 360; back >= 0; back--)
            {
                var day = today.AddDays(-back);
                var busy = back < 13 || rng.NextDouble() < (back < 200 ? 0.62 : 0.3);
                if (!busy) continue;
                var blocks = rng.Next(1, back < 40 ? 7 : 5);
                for (var b = 0; b < blocks; b++)
                {
                    var start = new DateTimeOffset(day.AddHours(9 + b * 1.5), TimeZoneInfo.Local.GetUtcOffset(day));
                    var minutes = b == 0 && rng.NextDouble() < 0.3 ? rng.Next(8, 20) : 25;
                    store.Save(new FocusSession
                    {
                        StartedAt = start, EndedAt = start.AddMinutes(minutes), FocusSeconds = minutes * 60,
                        PlannedSeconds = 1500, Completed = minutes == 25, Tag = tags[rng.Next(tags.Length)],
                        DeviceID = "demo", UpdatedAt = start.AddMinutes(minutes),
                    });
                }
            }
        }

        public void OpenMain() { }
        public void OpenSettings() { }
        public void OpenInspo() { }
        public void ShowAccount(FrameworkElement from) { }
        public void SetTheme(Theme theme) { }
        public void Quit() { }
    }
}
