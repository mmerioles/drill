using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using Drill.Core;
using Drill.Ink;
using Drill.Services;

namespace Drill.Views;

/// <summary>
/// A small window that pops up by the tray, as Windows 11's own flyouts do:
/// solid paper, rounded corners and a soft shadow from Windows, sliding up
/// 16px and fading in, and dropping away when you click elsewhere.
/// </summary>
public class PopupWindow : Window
{
    private nint _hwnd;
    private bool _closing;

    public PopupWindow(FrameworkElement content)
    {
        WindowStyle = WindowStyle.SingleBorderWindow; // keeps the shadow
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        SizeToContent = SizeToContent.WidthAndHeight;
        UseLayoutRounding = true;
        ShowActivated = true;
        SetResourceReference(BackgroundProperty, "Paper");
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.Grayscale);
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0,
            ResizeBorderThickness = new Thickness(0),
            GlassFrameThickness = new Thickness(-1),
            UseAeroCaptionButtons = false,
        });
        Content = content;
        Deactivated += (_, _) => Dismiss();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            Dismiss();
            e.Handled = true;
        };
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _hwnd = new WindowInteropHelper(this).Handle;
        var p = Palette.Current;
        Native.StyleFrame(_hwnd, p.Theme == Theme.Dark, p.Paper);
        Native.SetBorder(_hwnd, p.Theme == Theme.Dark ? Color.FromRgb(0x2E, 0x2E, 0x2D) : Color.FromRgb(0xD8, 0xD6, 0xD2));
        // Faded by the window's alpha, so the paper and its shadow fade together.
        Native.SetWindowLongW(_hwnd, Native.GWL_EXSTYLE,
                              Native.GetWindowLongW(_hwnd, Native.GWL_EXSTYLE) | Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW);
        Native.SetLayeredWindowAttributes(_hwnd, 0, 0, Native.LWA_ALPHA);
    }

    /// <summary>
    /// Opens next to the tray icon at `anchor` (pixels): above a bottom
    /// taskbar, beside a side one, below a top one, inside the work area.
    /// </summary>
    public void ShowNear(Native.RECT anchor)
    {
        var (monitor, work, scale) = Native.MonitorAround(anchor);
        Opacity = 1;
        Left = -32000; // measure off-screen first
        Top = -32000;
        Show();
        UpdateLayout();
        var w = ActualWidth * scale;
        var h = ActualHeight * scale;
        var gap = 12 * scale;

        double x, y;
        int dx = 0, dy = 0;
        var travel = (int)Math.Round(16 * scale);
        if (work.Bottom < monitor.Bottom) { y = work.Bottom - h - gap; x = anchor.Left + anchor.Width / 2.0 - w / 2; dy = travel; }
        else if (work.Top > monitor.Top) { y = work.Top + gap; x = anchor.Left + anchor.Width / 2.0 - w / 2; dy = -travel; }
        else if (work.Left > monitor.Left) { x = work.Left + gap; y = anchor.Top + anchor.Height / 2.0 - h / 2; dx = -travel; }
        else if (work.Right < monitor.Right) { x = work.Right - w - gap; y = anchor.Top + anchor.Height / 2.0 - h / 2; dx = travel; }
        else { x = anchor.Left - w / 2; y = anchor.Top - h - gap; dy = travel; } // auto-hidden taskbar: above the click
        x = Math.Clamp(x, work.Left + gap, work.Right - w - gap);
        y = Math.Clamp(y, work.Top + gap, work.Bottom - h - gap);

        Activate();
        Native.SetForegroundWindow(_hwnd);
        // Keyboard users start on the first thing to press.
        (Content as UIElement)?.MoveFocus(new TraversalRequest(FocusNavigationDirection.First));
        Slide((int)x, (int)y, dx, dy, opening: true, () => { });
    }

    /// <summary>On its way out (or gone).</summary>
    public bool IsDismissing => _closing || !IsVisible;

    public void Dismiss()
    {
        if (_closing || !IsVisible) return;
        _closing = true;
        Native.GetWindowRect(_hwnd, out var r);
        Slide(r.Left, r.Top, 0, (int)Math.Round(-8 * Native.ScaleOf(_hwnd)), opening: false, Close);
    }

    /// <summary>
    /// Moves from (x + dx, y + dy) to (x, y) while fading in, or from (x, y)
    /// away by (dx, dy) while fading out — per frame, on the compositor's clock.
    /// </summary>
    private void Slide(int x, int y, int dx, int dy, bool opening, Action done)
    {
        if (!Motion.Enabled)
        {
            Native.SetWindowPos(_hwnd, 0, x, y, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
            Native.SetLayeredWindowAttributes(_hwnd, 0, (byte)(opening ? 255 : 0), Native.LWA_ALPHA);
            done();
            return;
        }
        var moveMs = opening ? 250.0 : 120.0;
        var fadeMs = opening ? 167.0 : 120.0;
        var ease = opening ? BezierEase.Decelerate : BezierEase.Accelerate;
        var started = DateTime.UtcNow;
        void Frame(object? sender, EventArgs e)
        {
            var ms = (DateTime.UtcNow - started).TotalMilliseconds;
            var move = ease.Ease(Math.Min(1, ms / moveMs));
            var fade = Math.Min(1, ms / fadeMs);
            var (px, py) = opening
                ? (x + dx * (1 - move), y + dy * (1 - move))
                : (x - dx * move, y - dy * move);
            Native.SetWindowPos(_hwnd, 0, (int)Math.Round(px), (int)Math.Round(py), 0, 0,
                                Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
            Native.SetLayeredWindowAttributes(_hwnd, 0, (byte)Math.Round(255 * (opening ? fade : 1 - fade)), Native.LWA_ALPHA);
            if (ms < Math.Max(moveMs, fadeMs)) return;
            CompositionTarget.Rendering -= Frame;
            done();
        }
        CompositionTarget.Rendering += Frame;
    }
}

/// <summary>
/// The tray flyout, as the mac's menu bar panel: enough to run a session
/// without opening the window.
/// </summary>
public sealed class TrayPanel : UserControl
{
    private readonly AppModel _model;
    private readonly FadingText _status = new() { FontSize = 12, Opacity = InkLink.Rest, HorizontalAlignment = HorizontalAlignment.Right };
    private readonly RollingText _clock = new() { FontSize = 34, VerticalAlignment = VerticalAlignment.Center };
    private readonly DoodleRing _ring = new() { Width = 34, Height = 34, LineWidth = 2, VerticalAlignment = VerticalAlignment.Center };
    private readonly Capsule _primary = new() { FontSize = 13, MinWidth = 72, Padding = new Thickness(22, 7, 22, 8) };
    private readonly InkLink _reset = new() { Content = "reset", FontSize = 13, Margin = new Thickness(14, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _today = InspoPage.Text("", 13);
    private readonly Glyph _glyph = new() { Kind = GlyphKind.Drill, Width = 16, Height = 16, LineWidth = 1.4, Accent = true, VerticalAlignment = VerticalAlignment.Center };

    public TrayPanel(Shell shell, Action dismiss)
    {
        _model = shell.Model;
        Width = 280;
        var root = new StackPanel { Margin = new Thickness(18) };

        var top = new DockPanel();
        top.Children.Add(_glyph);
        var word = InspoPage.Text("drill", 14);
        word.FontWeight = FontWeights.Bold;
        word.SetResourceReference(TextBlock.FontFamilyProperty, "Display");
        word.Margin = new Thickness(7, 0, 0, 1);
        word.VerticalAlignment = VerticalAlignment.Center;
        top.Children.Add(word);
        top.Children.Add(_status);
        root.Children.Add(top);

        var middle = new DockPanel { Margin = new Thickness(0, 14, 0, 0) };
        DockPanel.SetDock(_ring, Dock.Right);
        middle.Children.Add(_ring);
        middle.Children.Add(_clock);
        _clock.HorizontalAlignment = HorizontalAlignment.Left;
        root.Children.Add(middle);

        var controls = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 14, 0, 0) };
        controls.Children.Add(_primary);
        var skip = new InkLink { Content = "skip", FontSize = 13, Margin = new Thickness(16, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        controls.Children.Add(skip);
        controls.Children.Add(_reset);
        root.Children.Add(controls);

        var rule = new System.Windows.Shapes.Rectangle { Height = 1, Margin = new Thickness(0, 14, 0, 14) };
        rule.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Ghost");
        root.Children.Add(rule);

        var bottom = new DockPanel();
        var label = InspoPage.Text("today", 13);
        label.Opacity = InkLink.Rest;
        _today.FontWeight = FontWeights.SemiBold;
        _today.Margin = new Thickness(5, 0, 0, 0);
        var links = new StackPanel { Orientation = Orientation.Horizontal };
        var open = new InkLink { Content = "open", FontSize = 13, Margin = new Thickness(0, 0, 12, 0) };
        var quit = new InkLink { Content = "quit", FontSize = 13 };
        links.Children.Add(open);
        links.Children.Add(quit);
        DockPanel.SetDock(links, Dock.Right);
        bottom.Children.Add(links);
        bottom.Children.Add(label);
        bottom.Children.Add(_today);
        root.Children.Add(bottom);
        Content = root;

        _primary.Click += (_, _) => _model.Toggle();
        skip.Click += (_, _) => _model.Skip();
        _reset.Click += (_, _) => _model.Reset();
        open.Click += (_, _) => { dismiss(); shell.OpenMain(); };
        quit.Click += (_, _) => shell.Quit();

        Loaded += (_, _) =>
        {
            _model.PropertyChanged -= OnModel; // Loaded can come twice
            _model.PropertyChanged += OnModel;
            Show();
        };
        Unloaded += (_, _) => _model.PropertyChanged -= OnModel;
        Show();
    }

    /// <summary>Only what changed: the clock ticks a dozen properties a second.</summary>
    private void OnModel(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppModel.Clock): ShowClock(); break;
            case nameof(AppModel.Progress): _ring.Progress = _model.Progress; break;
            case nameof(AppModel.Status): _status.Text = _model.Status; break;
            case nameof(AppModel.IsRunning): _glyph.Boiling = _model.IsRunning; break;
            case nameof(AppModel.PrimaryLabel): _primary.Content = _model.PrimaryLabel; break;
            case nameof(AppModel.IsActive): _reset.Visibility = _model.IsActive ? Visibility.Visible : Visibility.Collapsed; break;
            case nameof(AppModel.Heatmap): _today.Text = Copy.Amount(_model.Heatmap.Today); break;
            case null or "": Show(); break;
        }
    }

    private void Show()
    {
        _status.Text = _model.Status;
        ShowClock();
        _ring.Progress = _model.Progress;
        _ring.Boiling = false;
        _glyph.Boiling = _model.IsRunning;
        _primary.Content = _model.PrimaryLabel;
        _reset.Visibility = _model.IsActive ? Visibility.Visible : Visibility.Collapsed;
        _today.Text = Copy.Amount(_model.Heatmap.Today);
    }

    private void ShowClock()
    {
        _clock.Text = _model.Clock;
        System.Windows.Automation.AutomationProperties.SetName(_clock, _model.Spoken);
    }
}

/// <summary>The tray's right-click menu: a few plain words, in ink.</summary>
public sealed class TrayMenu : UserControl
{
    public TrayMenu(Shell shell, Action dismiss)
    {
        var m = shell.Model;
        var list = new StackPanel { Margin = new Thickness(4), MinWidth = 180 };
        void Item(string label, Action act)
        {
            var b = new Button { Content = label, Template = ItemTemplate(), Cursor = Cursors.Arrow };
            b.Click += (_, _) => { dismiss(); act(); };
            list.Children.Add(b);
        }
        void Rule()
        {
            var r = new System.Windows.Shapes.Rectangle { Height = 1, Margin = new Thickness(-4, 4, -4, 4) };
            r.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Ghost");
            list.Children.Add(r);
        }
        Item(m.PrimaryLabel, m.Toggle);
        Item("skip", m.Skip);
        if (m.IsActive) Item("reset", m.Reset);
        Rule();
        Item("open drill", shell.OpenMain);
        Item("settings", shell.OpenSettings);
        Rule();
        Item("quit", shell.Quit);
        Content = list;
    }

    /// <summary>A Windows 11 menu row: 4px radius, a hover wash, 14px text.</summary>
    private static ControlTemplate ItemTemplate()
    {
        var t = new ControlTemplate(typeof(Button));
        var back = new FrameworkElementFactory(typeof(Border), "Back");
        back.SetValue(Border.CornerRadiusProperty, new CornerRadius(4));
        back.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        back.SetValue(Border.PaddingProperty, new Thickness(12, 7, 12, 8));
        var text = new FrameworkElementFactory(typeof(TextBlock));
        text.SetValue(TextBlock.TextProperty, new System.Windows.Data.Binding("Content") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        text.SetValue(TextBlock.FontSizeProperty, 14.0);
        text.SetResourceReference(TextBlock.FontFamilyProperty, "Text");
        text.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
        back.AppendChild(text);
        t.VisualTree = back;
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, new DynamicResourceExtension("Hover"), "Back"));
        var focus = new Trigger { Property = IsKeyboardFocusedProperty, Value = true };
        focus.Setters.Add(new Setter(Border.BackgroundProperty, new DynamicResourceExtension("Hover"), "Back"));
        t.Triggers.Add(hover);
        t.Triggers.Add(focus);
        return t;
    }
}
