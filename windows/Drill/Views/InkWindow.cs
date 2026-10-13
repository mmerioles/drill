using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using Drill.Ink;
using Drill.Services;

namespace Drill.Views;

/// <summary>
/// What every drill window puts around its page: the paper running up under
/// a 32px caption band with drawn minimize and close buttons, a layer for
/// dialogs, and a layer for the theme crossfade. It's a plain element, so
/// --render can draw a window's whole face without opening one.
/// </summary>
public sealed class InkFrame : Grid
{
    public const double CaptionHeight = 32;

    public FrameworkElement Page { get; }
    public DialogHost Dialogs { get; } = new();
    public Button? Minimize { get; }
    public Button Close { get; }

    private readonly Image _fade = new() { IsHitTestVisible = false, Stretch = Stretch.Fill };
    private readonly StackPanel _caption;

    public InkFrame(FrameworkElement page, bool minimizable = true)
    {
        Page = page;
        SetResourceReference(BackgroundProperty, "Paper");
        UseLayoutRounding = true;
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.Grayscale);
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        RenderOptions.SetClearTypeHint(this, ClearTypeHint.Auto);

        page.Margin = new Thickness(0, CaptionHeight, 0, 0);
        Children.Add(page);

        _caption = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
        };
        if (minimizable)
        {
            Minimize = Caption("", "CaptionButton", "minimize");
            _caption.Children.Add(Minimize);
        }
        Close = Caption("", "CloseButton", "close");
        _caption.Children.Add(Close);
        Children.Add(_caption);

        Children.Add(Dialogs);
        Children.Add(_fade);
    }

    private static Button Caption(string glyph, string style, string name)
    {
        var b = new Button { Content = glyph, ToolTip = name };
        b.SetResourceReference(StyleProperty, style);
        WindowChrome.SetIsHitTestVisibleInChrome(b, true);
        AutomationName(b, name);
        return b;
    }

    internal static void AutomationName(DependencyObject d, string name) =>
        System.Windows.Automation.AutomationProperties.SetName(d, name);

    /// <summary>Inactive windows grey their caption glyphs, as Windows does.</summary>
    public void SetActive(bool active)
    {
        foreach (Button b in _caption.Children) b.Opacity = active ? 1 : 0.45;
    }

    /// <summary>
    /// Crossfades to a new theme: a snapshot of the old look on top, fading
    /// out over 250ms while everything underneath is already re-themed.
    /// </summary>
    public void Crossfade(Action retheme)
    {
        if (!Motion.Enabled || ActualWidth <= 0 || !IsVisible)
        {
            retheme();
            return;
        }
        var dpi = VisualTreeHelper.GetDpi(this);
        var shot = new RenderTargetBitmap((int)Math.Ceiling(ActualWidth * dpi.DpiScaleX), (int)Math.Ceiling(ActualHeight * dpi.DpiScaleY),
                                          dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        _fade.Visibility = Visibility.Collapsed;
        shot.Render(this);
        shot.Freeze();
        _fade.Source = shot;
        _fade.Visibility = Visibility.Visible;
        _fade.Opacity = 1;
        retheme();
        Animate.Settle(_fade, OpacityProperty, 1, 0, 250, BezierEase.Out, () => { _fade.Source = null; _fade.Visibility = Visibility.Collapsed; });
    }
}

/// <summary>
/// A drill window: the frame, Windows 11's rounded corners and shadow, and
/// a title bar that's just paper. Sized to its page, and scaled down to fit
/// small screens rather than cut off.
/// </summary>
public class InkWindow : Window
{
    public InkFrame Frame { get; }
    private readonly App _app;

    public InkWindow(FrameworkElement page, string title, bool minimizable = true)
    {
        _app = (App)Application.Current;
        Frame = new InkFrame(page, minimizable);
        Title = title;
        Content = Frame;
        SetResourceReference(BackgroundProperty, "Paper");
        ResizeMode = minimizable ? ResizeMode.CanMinimize : ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        UseLayoutRounding = true;

        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = InkFrame.CaptionHeight,
            ResizeBorderThickness = new Thickness(0),
            GlassFrameThickness = new Thickness(-1),
            CornerRadius = new CornerRadius(0),
            UseAeroCaptionButtons = false,
        });

        if (Frame.Minimize is { } min) min.Click += (_, _) => WindowState = WindowState.Minimized;
        Frame.Close.Click += (_, _) => Close();
        Activated += (_, _) => Frame.SetActive(true);
        Deactivated += (_, _) => Frame.SetActive(false);
        Palette.Changed += Restyle;
        Closed += (_, _) => Palette.Changed -= Restyle;
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && Frame.Dialogs.IsOpen)
            {
                Frame.Dialogs.Close();
                e.Handled = true;
            }
        };
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        // Before the first frame, so dark never flashes white.
        Restyle();
        FitScreen();
    }

    private void Restyle()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == 0) return;
        var p = Palette.Current;
        Native.StyleFrame(hwnd, p.Theme == Theme.Dark, p.Paper);
        // A hairline just off the paper, so the window's edge reads on any wallpaper.
        Native.SetBorder(hwnd, p.Theme == Theme.Dark ? Color.FromRgb(0x2A, 0x2A, 0x29) : Color.FromRgb(0xDC, 0xDA, 0xD6));
    }

    /// <summary>Shrinks the whole layout on screens too short for it (1366×768 at 100%, say).</summary>
    private void FitScreen()
    {
        var work = SystemParameters.WorkArea;
        Frame.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var want = Frame.DesiredSize;
        var scale = Math.Min(1, Math.Min((work.Height - 16) / want.Height, (work.Width - 16) / want.Width));
        if (scale < 0.999) Frame.LayoutTransform = new ScaleTransform(scale, scale);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        _app.WindowClosing(this, e);
    }

    /// <summary>Back in front, wherever it was.</summary>
    public void Present()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        var hwnd = new WindowInteropHelper(this).Handle;
        Native.SetForegroundWindow(hwnd);
        Focus();
    }
}

/// <summary>
/// Dialogs over a window, as Windows 11 does them: a smoke scrim fades in and
/// the card settles from 1.05× to size. Esc or clicking the smoke closes.
/// </summary>
public sealed class DialogHost : Grid
{
    private readonly Border _smoke = new();
    private readonly Border _card = new()
    {
        CornerRadius = new CornerRadius(8),
        BorderThickness = new Thickness(1),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Width = 400,
        Padding = new Thickness(24),
        RenderTransformOrigin = new Point(0.5, 0.5),
        Effect = new System.Windows.Media.Effects.DropShadowEffect
        {
            BlurRadius = 32, ShadowDepth = 8, Direction = 270, Opacity = 0.18, Color = Colors.Black,
        },
    };
    private IInputElement? _returnFocus;
    private Action? _onClosed;

    public DialogHost()
    {
        Visibility = Visibility.Collapsed;
        _smoke.SetResourceReference(Border.BackgroundProperty, "Smoke");
        _smoke.MouseLeftButtonDown += (_, _) => Close();
        _card.SetResourceReference(Border.BackgroundProperty, "Raised");
        _card.SetResourceReference(Border.BorderBrushProperty, "Border");
        Children.Add(_smoke);
        Children.Add(_card);
        KeyboardNavigation.SetTabNavigation(_card, KeyboardNavigationMode.Cycle);
    }

    public bool IsOpen => Visibility == Visibility.Visible;
    public FrameworkElement? Current => _card.Child as FrameworkElement;

    public void Show(FrameworkElement content, Action? onClosed = null)
    {
        _returnFocus = Keyboard.FocusedElement;
        _onClosed = onClosed;
        _card.Child = content;
        Visibility = Visibility.Visible;
        var scale = new ScaleTransform(1.05, 1.05);
        _card.RenderTransform = scale;
        Animate.Settle(scale, ScaleTransform.ScaleXProperty, 1.05, 1, 250, BezierEase.Decelerate, () => _card.RenderTransform = null);
        Animate.Settle(scale, ScaleTransform.ScaleYProperty, 1.05, 1, 250, BezierEase.Decelerate);
        Animate.Settle(_card, OpacityProperty, 0, 1, 83, BezierEase.Out);
        Animate.Settle(_smoke, OpacityProperty, 0, 1, 167, BezierEase.Out);
    }

    public void Close()
    {
        if (!IsOpen) return;
        var closing = _card.Child;
        Animate.Settle(_card, OpacityProperty, 1, 0, 120, BezierEase.Accelerate);
        Animate.Settle(_smoke, OpacityProperty, 1, 0, 167, BezierEase.Accelerate, () =>
        {
            if (_card.Child != closing) return; // another opened meanwhile
            Visibility = Visibility.Collapsed;
            _card.Child = null;
            _returnFocus?.Focus();
            var done = _onClosed;
            _onClosed = null;
            done?.Invoke();
        });
    }
}
