using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Drill.Ink;

/// <summary>A CSS-style cubic-bezier(x1, y1, x2, y2) easing, for the Windows 11 motion curves.</summary>
public sealed class BezierEase : EasingFunctionBase
{
    public double X1 { get; set; }
    public double Y1 { get; set; }
    public double X2 { get; set; } = 1;
    public double Y2 { get; set; } = 1;

    public BezierEase() => EasingMode = EasingMode.EaseIn; // EaseIn = the curve as given

    public BezierEase(double x1, double y1, double x2, double y2) : this() => (X1, Y1, X2, Y2) = (x1, y1, x2, y2);

    protected override double EaseInCore(double t)
    {
        // Solve x(s) = t for s by Newton's method, then return y(s).
        var s = t;
        for (var i = 0; i < 8; i++)
        {
            var x = Bez(s, X1, X2) - t;
            var dx = DBez(s, X1, X2);
            if (Math.Abs(x) < 1e-5) break;
            if (Math.Abs(dx) < 1e-6) break;
            s = Math.Clamp(s - x / dx, 0, 1);
        }
        return Bez(s, Y1, Y2);
    }

    private static double Bez(double s, double p1, double p2) =>
        3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s;

    private static double DBez(double s, double p1, double p2) =>
        3 * (1 - s) * (1 - s) * p1 + 6 * (1 - s) * s * (p2 - p1) + 3 * s * s * (1 - p2);

    protected override Freezable CreateInstanceCore() => new BezierEase(X1, Y1, X2, Y2);

    public static readonly BezierEase Decelerate = Frozen(0, 0, 0, 1);
    public static readonly BezierEase Accelerate = Frozen(1, 0, 1, 1);
    public static readonly BezierEase Glide = Frozen(0.1, 0.9, 0.2, 1);
    /// <summary>The digit roll's curve.</summary>
    public static readonly BezierEase Roll = Frozen(0.2, 0, 0, 1);
    /// <summary>Plain ease-out, for fades.</summary>
    public static readonly BezierEase Out = Frozen(0, 0, 0.58, 1);
    public static readonly BezierEase InOut = Frozen(0.42, 0, 0.58, 1);

    private static BezierEase Frozen(double a, double b, double c, double d)
    {
        var e = new BezierEase(a, b, c, d);
        e.Freeze();
        return e;
    }
}

/// <summary>Animation helpers that respect Windows' animation setting.</summary>
public static class Animate
{
    public static void To(IAnimatable target, DependencyProperty property, double to, double ms, IEasingFunction? ease = null,
                          Action? done = null)
    {
        if (!Motion.Enabled || ms <= 0)
        {
            target.BeginAnimation(property, null);
            if (target is DependencyObject d) d.SetValue(property, to);
            done?.Invoke();
            return;
        }
        var a = new DoubleAnimation(to, TimeSpan.FromMilliseconds(ms)) { EasingFunction = ease ?? BezierEase.Out };
        if (done is not null) a.Completed += (_, _) => done();
        target.BeginAnimation(property, a, HandoffBehavior.SnapshotAndReplace);
    }

    /// <summary>Animates, then lets go of the property at its final value.</summary>
    public static void Settle(IAnimatable target, DependencyProperty property, double from, double to, double ms,
                              IEasingFunction? ease = null, Action? done = null)
    {
        if (target is not DependencyObject d) return;
        if (!Motion.Enabled || ms <= 0)
        {
            target.BeginAnimation(property, null);
            d.SetValue(property, to);
            done?.Invoke();
            return;
        }
        var a = new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(ms)) { EasingFunction = ease ?? BezierEase.Out };
        a.Completed += (_, _) =>
        {
            target.BeginAnimation(property, null);
            d.SetValue(property, to);
            done?.Invoke();
        };
        target.BeginAnimation(property, a, HandoffBehavior.SnapshotAndReplace);
    }
}

/// <summary>Faint lowercase words that darken under the pointer, as InkLinkStyle.</summary>
public sealed class InkLink : Button
{
    public static readonly DependencyProperty IsSelectedProperty = DependencyProperty.Register(
        nameof(IsSelected), typeof(bool), typeof(InkLink), new PropertyMetadata(false, (d, _) => ((InkLink)d).Shade()));

    public static readonly DependencyProperty InkProperty = DependencyProperty.Register(
        nameof(Ink), typeof(double), typeof(InkLink), new PropertyMetadata(Rest));

    private const double Rest = 0.45;

    public InkLink()
    {
        MouseEnter += (_, _) => Shade();
        MouseLeave += (_, _) => Shade();
        IsEnabledChanged += (_, _) => Shade();
    }

    public bool IsSelected
    {
        get => (bool)GetValue(IsSelectedProperty);
        set => SetValue(IsSelectedProperty, value);
    }

    /// <summary>How much ink: 0.45 at rest, full under the pointer or when selected.</summary>
    public double Ink
    {
        get => (double)GetValue(InkProperty);
        set => SetValue(InkProperty, value);
    }

    protected override void OnIsPressedChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnIsPressedChanged(e);
        Shade();
    }

    private void Shade()
    {
        var target = IsSelected || (IsMouseOver && IsEnabled) ? 1 : Rest;
        if (IsPressed) target *= 0.5;
        Animate.To(this, InkProperty, target, 120);
    }
}

/// <summary>The ink capsule: fades a touch under the pointer and gives under a press.</summary>
public sealed class Capsule : Button
{
    public static readonly DependencyProperty FadeProperty = DependencyProperty.Register(
        nameof(Fade), typeof(double), typeof(Capsule), new PropertyMetadata(1.0));

    private readonly ScaleTransform _scale = new(1, 1);

    public Capsule()
    {
        RenderTransform = _scale;
        MouseEnter += (_, _) => Shade();
        MouseLeave += (_, _) => Shade();
        IsEnabledChanged += (_, _) => Shade();
        // Padding scales with the type, as on the mac (size × 2.6, × 0.85),
        // unless a style or the page sets its own.
        Loaded += (_, _) =>
        {
            if (Padding == default) Padding = new Thickness(FontSize * 2.6, FontSize * 0.85, FontSize * 2.6, FontSize * 0.85);
        };
    }

    public double Fade
    {
        get => (double)GetValue(FadeProperty);
        set => SetValue(FadeProperty, value);
    }

    protected override void OnIsPressedChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnIsPressedChanged(e);
        var to = IsPressed ? 0.96 : 1;
        // A quick spring: a little overshoot coming back.
        var ease = IsPressed ? (IEasingFunction)BezierEase.Decelerate : new BackEase { Amplitude = 0.35, EasingMode = EasingMode.EaseOut };
        var ms = IsPressed ? 90 : 260;
        Animate.To(_scale, ScaleTransform.ScaleXProperty, to, ms, ease, done: () => { if (!IsPressed) SnapBack(); });
        Animate.To(_scale, ScaleTransform.ScaleYProperty, to, ms, ease);
    }

    /// <summary>Back to no transform at rest, so text renders crisp again.</summary>
    private void SnapBack()
    {
        _scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        _scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        _scale.ScaleX = _scale.ScaleY = 1;
    }

    private void Shade() =>
        Animate.To(this, FadeProperty, !IsEnabled ? 0.5 : IsMouseOver ? 0.86 : 1, 120);
}

/// <summary>
/// The Windows 11 toggle switch, in ink: a 40×20 track, a 12px thumb that
/// grows to 14 under the pointer and stretches to 17 while pressed. On is an
/// ink track with a paper thumb.
/// </summary>
public sealed class Toggle : FrameworkElement
{
    public static readonly DependencyProperty IsOnProperty = DependencyProperty.Register(
        nameof(IsOn), typeof(bool), typeof(Toggle),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, (d, _) => ((Toggle)d).Move()));

    private static readonly DependencyProperty PositionProperty = DependencyProperty.Register(
        "Position", typeof(double), typeof(Toggle), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    private static readonly DependencyProperty ThumbProperty = DependencyProperty.Register(
        "Thumb", typeof(double), typeof(Toggle), new FrameworkPropertyMetadata(12.0, FrameworkPropertyMetadataOptions.AffectsRender));
    private static readonly DependencyProperty StretchProperty = DependencyProperty.Register(
        "Stretch", typeof(double), typeof(Toggle), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public Toggle()
    {
        Focusable = true;
        Width = 40;
        Height = 20;
        Loaded += (_, _) => { Palette.Changed += InvalidateVisual; SetValue(PositionProperty, IsOn ? 1.0 : 0.0); };
        Unloaded += (_, _) => Palette.Changed -= InvalidateVisual;
        MouseEnter += (_, _) => Size();
        MouseLeave += (_, _) => { _pressed = false; Size(); };
    }

    private bool _pressed;

    public bool IsOn
    {
        get => (bool)GetValue(IsOnProperty);
        set => SetValue(IsOnProperty, value);
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        _pressed = true;
        Focus();
        Keyboard.ClearFocus(); // no ring for clicks
        Size();
        e.Handled = true;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (_pressed) IsOn = !IsOn;
        _pressed = false;
        Size();
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key is Key.Space or Key.Enter)
        {
            IsOn = !IsOn;
            e.Handled = true;
        }
    }

    private void Move() => Animate.To(this, PositionProperty, IsOn ? 1 : 0, 167, BezierEase.Decelerate);

    private void Size()
    {
        Animate.To(this, ThumbProperty, IsMouseOver || _pressed ? 14 : 12, 167, BezierEase.Decelerate);
        Animate.To(this, StretchProperty, _pressed ? 3 : 0, 167, BezierEase.Decelerate);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var p = Palette.Current;
        var pos = (double)GetValue(PositionProperty);
        var thumb = (double)GetValue(ThumbProperty);
        var stretch = (double)GetValue(StretchProperty);
        var track = new Rect(0.5, 0.5, 39, 19);

        // Off: a hairline outline. On: solid ink. Crossfaded with the slide.
        dc.PushOpacity(1 - pos);
        dc.DrawRoundedRectangle(null, new Pen(Palette.Brush(p.Faint), 1), track, 9.5, 9.5);
        dc.Pop();
        dc.PushOpacity(pos);
        dc.DrawRoundedRectangle(Palette.Brush(p.Ink), null, track, 9.5, 9.5);
        dc.Pop();

        var w = thumb + stretch;
        var left = 4 + (thumb == 12 ? 0 : -(thumb - 12) / 2);
        var right = 36 - w + (thumb == 12 ? 0 : (thumb - 12) / 2);
        var x = left + (right - left) * pos;
        var thumbColor = Lerp(p.Faint, p.Paper, pos);
        dc.DrawRoundedRectangle(Palette.Brush(thumbColor), null, new Rect(x, 10 - thumb / 2, w, thumb), thumb / 2, thumb / 2);
    }

    private static Color Lerp(Color a, Color b, double t) => Color.FromArgb(
        (byte)(a.A + (b.A - a.A) * t), (byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t));
}

/// <summary>"–  25 min  +": a number with 32px buttons; arrow keys and the wheel step it too.</summary>
public sealed class Stepper : UserControl
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(int), typeof(Stepper),
        new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, (d, _) => ((Stepper)d).Show()));

    public int Minimum { get; set; }
    public int Maximum { get; set; } = 100;
    public int Step { get; set; } = 1;
    public string Unit { get; set; } = "";

    private readonly TextBlock _label = new() { MinWidth = 52, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _less;
    private readonly Button _more;

    public Stepper()
    {
        Focusable = true;
        IsTabStop = true;
        _less = Make("", -1); // Remove
        _more = Make("", +1); // Add
        _label.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
        _label.SetResourceReference(TextBlock.FontFamilyProperty, "Text");
        _label.FontSize = 14;
        Typography.SetNumeralAlignment(_label, FontNumeralAlignment.Tabular);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(_less);
        row.Children.Add(_label);
        row.Children.Add(_more);
        Content = row;
        Show();
    }

    public int Value
    {
        get => (int)GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
    }

    private Button Make(string glyph, int direction)
    {
        var b = new Button { Content = glyph, Width = 32, Height = 32, Focusable = false };
        b.SetResourceReference(StyleProperty, "CaptionButton");
        b.FontSize = 11;
        b.Template = RoundTemplate();
        b.Click += (_, _) => Nudge(direction);
        return b;
    }

    /// <summary>The caption button look, rounded for use on a card.</summary>
    private static ControlTemplate RoundTemplate()
    {
        var t = new ControlTemplate(typeof(Button));
        var back = new FrameworkElementFactory(typeof(Border), "Back");
        back.SetValue(Border.CornerRadiusProperty, new CornerRadius(4));
        back.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        var mark = new FrameworkElementFactory(typeof(TextBlock));
        mark.SetValue(TextBlock.TextProperty, new System.Windows.Data.Binding("Content") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        mark.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        mark.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        mark.SetValue(TextBlock.ForegroundProperty, new TemplateBindingExtension(ForegroundProperty));
        back.AppendChild(mark);
        t.VisualTree = back;
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, new DynamicResourceExtension("Hover"), "Back"));
        var press = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
        press.Setters.Add(new Setter(Border.BackgroundProperty, new DynamicResourceExtension("Press"), "Back"));
        t.Triggers.Add(hover);
        t.Triggers.Add(press);
        return t;
    }

    private void Nudge(int direction) => Value = Math.Clamp(Value + direction * Step, Minimum, Maximum);

    private void Show()
    {
        _label.Text = Unit.Length > 0 ? $"{Value} {Unit}" : $"{Value}";
        _less.IsEnabled = Value > Minimum;
        _more.IsEnabled = Value < Maximum;
        _less.Opacity = _less.IsEnabled ? 1 : 0.35;
        _more.Opacity = _more.IsEnabled ? 1 : 0.35;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Up or Key.Right: Nudge(+1); e.Handled = true; break;
            case Key.Down or Key.Left: Nudge(-1); e.Handled = true; break;
        }
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        Nudge(Math.Sign(e.Delta));
        e.Handled = true;
    }
}

/// <summary>"light | dark": a pill track with an ink thumb that glides between choices.</summary>
public sealed class Segmented : FrameworkElement
{
    public static readonly DependencyProperty SelectedIndexProperty = DependencyProperty.Register(
        nameof(SelectedIndex), typeof(int), typeof(Segmented),
        new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, (d, _) => ((Segmented)d).Glide()));

    private static readonly DependencyProperty SlideProperty = DependencyProperty.Register(
        "Slide", typeof(double), typeof(Segmented), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public IReadOnlyList<string> Items { get; set; } = [];
    private const double Segment = 64, Tall = 30;
    private int _hover = -1;

    public Segmented()
    {
        Focusable = true;
        Loaded += (_, _) => { Palette.Changed += InvalidateVisual; SetValue(SlideProperty, (double)SelectedIndex); };
        Unloaded += (_, _) => Palette.Changed -= InvalidateVisual;
        MouseLeave += (_, _) => { _hover = -1; InvalidateVisual(); };
        Cursor = Cursors.Hand;
    }

    public int SelectedIndex
    {
        get => (int)GetValue(SelectedIndexProperty);
        set => SetValue(SelectedIndexProperty, value);
    }

    protected override Size MeasureOverride(Size available) => new(Segment * Items.Count + 4, Tall + 4);

    private void Glide() => Animate.To(this, SlideProperty, SelectedIndex, 250, BezierEase.Glide);

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var i = (int)((e.GetPosition(this).X - 2) / Segment);
        if (i != _hover) { _hover = i; InvalidateVisual(); }
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        var i = (int)((e.GetPosition(this).X - 2) / Segment);
        if (i >= 0 && i < Items.Count) SelectedIndex = i;
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key is Key.Left) SelectedIndex = Math.Max(0, SelectedIndex - 1);
        else if (e.Key is Key.Right) SelectedIndex = Math.Min(Items.Count - 1, SelectedIndex + 1);
        else return;
        e.Handled = true;
    }

    protected override void OnRender(DrawingContext dc)
    {
        var p = Palette.Current;
        var all = new Rect(0, 0, Segment * Items.Count + 4, Tall + 4);
        dc.DrawRoundedRectangle(Palette.Brush(Palette.WithAlpha(p.Ink, 0.06)), null, all, all.Height / 2, all.Height / 2);
        var slide = (double)GetValue(SlideProperty);
        var thumb = new Rect(2 + slide * Segment, 2, Segment, Tall);
        dc.DrawRoundedRectangle(Palette.Brush(p.Ink), null, thumb, Tall / 2, Tall / 2);

        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        for (var i = 0; i < Items.Count; i++)
        {
            // Label colour follows the thumb as it passes over.
            var cover = Math.Clamp(1 - Math.Abs(slide - i), 0, 1);
            var rest = i == _hover ? p.Ink : p.Faint;
            var color = Color.FromArgb(
                (byte)(rest.A + (p.Paper.A - rest.A) * cover), (byte)(rest.R + (p.Paper.R - rest.R) * cover),
                (byte)(rest.G + (p.Paper.G - rest.G) * cover), (byte)(rest.B + (p.Paper.B - rest.B) * cover));
            var text = new FormattedText(Items[i], System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                Typeface("Text", cover > 0.5 ? FontWeights.SemiBold : FontWeights.Normal), 13, Palette.Brush(color), dpi);
            dc.DrawText(text, new Point(2 + i * Segment + (Segment - text.Width) / 2, 2 + (Tall - text.Height) / 2));
        }
    }

    internal static Typeface Typeface(string key, FontWeight weight) =>
        new((FontFamily)Application.Current.FindResource(key), FontStyles.Normal, weight, FontStretches.Normal);
}

/// <summary>A line of text that crossfades when it changes, as the mac's .contentTransition(.opacity).</summary>
public sealed class FadingText : Grid
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(FadingText), new PropertyMetadata(null, (d, e) => ((FadingText)d).Change((string?)e.NewValue)));

    public double Duration { get; set; } = 500;

    private TextBlock _shown;

    public FadingText()
    {
        _shown = Line(null);
        Children.Add(_shown);
    }

    public string? Text
    {
        get => (string?)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public double FontSize
    {
        get => (double)GetValue(TextElement.FontSizeProperty);
        set => SetValue(TextElement.FontSizeProperty, value);
    }

    private TextBlock Line(string? text)
    {
        var t = new TextBlock { Text = text ?? "", HorizontalAlignment = HorizontalAlignment.Center };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
        t.SetResourceReference(TextBlock.FontFamilyProperty, "Text");
        return t;
    }

    private void Change(string? text)
    {
        if (_shown.Text == (text ?? "")) return;
        if (!Motion.Enabled || !IsLoaded)
        {
            _shown.Text = text ?? "";
            return;
        }
        var old = _shown;
        _shown = Line(text);
        Children.Add(_shown);
        Animate.Settle(_shown, OpacityProperty, 0, 1, Duration, BezierEase.Out);
        Animate.Settle(old, OpacityProperty, old.Opacity, 0, Duration, BezierEase.Out, () => Children.Remove(old));
    }
}
