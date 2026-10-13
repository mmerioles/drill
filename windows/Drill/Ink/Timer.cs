using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using Drill.Core;
using Drill.Core.Stats;

namespace Drill.Ink;

/// <summary>
/// The countdown's digits. A character that changes rolls: the old one
/// slides down and fades as the new one drops in from above (counting down
/// reads as falling), clipped to its own cell. Once a roll settles, the
/// transform is dropped so the text rasterizes crisp again.
/// </summary>
public sealed class RollingText : FrameworkElement
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(RollingText), new PropertyMetadata("", (d, e) => ((RollingText)d).Change((string)e.OldValue, (string)e.NewValue)));

    public static readonly DependencyProperty FontSizeProperty = TextElement.FontSizeProperty.AddOwner(typeof(RollingText));

    private readonly Grid _row = new() { ClipToBounds = false };
    private readonly List<Grid> _cells = [];

    public RollingText()
    {
        AddVisualChild(_row);
        AddLogicalChild(_row);
    }

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public double FontSize
    {
        get => (double)GetValue(FontSizeProperty);
        set => SetValue(FontSizeProperty, value);
    }

    protected override int VisualChildrenCount => 1;
    protected override Visual GetVisualChild(int index) => _row;
    protected override Size MeasureOverride(Size available)
    {
        _row.Measure(available);
        return _row.DesiredSize;
    }
    protected override Size ArrangeOverride(Size final)
    {
        _row.Arrange(new Rect(final));
        return final;
    }

    private void Change(string old, string text)
    {
        // A different shape (25:00 → 1:00:00): rebuild without a roll.
        if (old.Length != text.Length || _cells.Count != text.Length || !Motion.Enabled || !IsLoaded)
        {
            Rebuild(text);
            return;
        }
        for (var i = 0; i < text.Length; i++)
        {
            if (old[i] != text[i]) Roll(_cells[i], text[i]);
        }
    }

    private void Rebuild(string text)
    {
        _row.Children.Clear();
        _row.ColumnDefinitions.Clear();
        _cells.Clear();
        for (var i = 0; i < text.Length; i++)
        {
            _row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var cell = new Grid { ClipToBounds = true };
            Grid.SetColumn(cell, i);
            cell.Children.Add(Glyph(text[i]));
            _row.Children.Add(cell);
            _cells.Add(cell);
        }
    }

    private TextBlock Glyph(char c)
    {
        var t = new TextBlock
        {
            Text = c.ToString(),
            FontSize = FontSize,
            FontWeight = FontWeights.Bold,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        t.SetResourceReference(TextBlock.FontFamilyProperty, "Display");
        t.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
        Typography.SetNumeralAlignment(t, FontNumeralAlignment.Tabular);
        TextOptions.SetTextFormattingMode(t, TextFormattingMode.Ideal);
        // Segoe's colon sits low between numerals: lift it a little.
        if (c == ':') t.Margin = new Thickness(FontSize * 0.02, -FontSize * 0.06, FontSize * 0.02, FontSize * 0.06);
        return t;
    }

    private void Roll(Grid cell, char next)
    {
        var travel = FontSize * 0.35;
        // Anything still leaving goes now; the newest arrival becomes the leaver.
        while (cell.Children.Count > 1) cell.Children.RemoveAt(0);
        var leaving = (TextBlock)cell.Children[0];
        var arriving = Glyph(next);
        cell.Children.Add(arriving);

        var down = new TranslateTransform();
        leaving.RenderTransform = down;
        Animate.Settle(down, TranslateTransform.YProperty, 0, travel, 220, BezierEase.Roll, () => cell.Children.Remove(leaving));
        Animate.Settle(leaving, OpacityProperty, 1, 0, 160, BezierEase.Roll);

        var drop = new TranslateTransform(0, -travel);
        arriving.RenderTransform = drop;
        arriving.Opacity = 0;
        Animate.Settle(drop, TranslateTransform.YProperty, -travel, 0, 220, BezierEase.Roll, () => arriving.RenderTransform = null);
        Animate.Settle(arriving, OpacityProperty, 0, 1, 220, BezierEase.Roll);
    }
}

/// <summary>Where you are in the long-break cycle: small inked dots, filled as you go.</summary>
public sealed class CycleDots : FrameworkElement
{
    public static readonly DependencyProperty FilledProperty = DependencyProperty.Register(
        nameof(Filled), typeof(int), typeof(CycleDots), new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty CountProperty = DependencyProperty.Register(
        nameof(Count), typeof(int), typeof(CycleDots), new FrameworkPropertyMetadata(4, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

    public CycleDots()
    {
        Loaded += (_, _) => Palette.Changed += InvalidateVisual;
        Unloaded += (_, _) => Palette.Changed -= InvalidateVisual;
    }

    public int Filled
    {
        get => (int)GetValue(FilledProperty);
        set => SetValue(FilledProperty, value);
    }

    public int Count
    {
        get => (int)GetValue(CountProperty);
        set => SetValue(CountProperty, value);
    }

    private const double Size = 6, Gap = 7;

    protected override System.Windows.Size MeasureOverride(System.Windows.Size available) =>
        new(Count * Size + Math.Max(0, Count - 1) * Gap, Size);

    protected override void OnRender(DrawingContext dc)
    {
        var p = Palette.Current;
        var pen = new Pen(Palette.Brush(p.Faint), 1);
        for (var i = 0; i < Count; i++)
        {
            var center = new Point(i * (Size + Gap) + Size / 2, Size / 2);
            dc.DrawEllipse(i < Filled ? Palette.Brush(p.Ink) : null, pen, center, Size / 2 - 0.5, Size / 2 - 0.5);
        }
    }
}

/// <summary>
/// A year of study, a week per column. Cells are inked squares whose density
/// is the day's focus time; each wobbles by its own fixed seed, so the grid
/// looks hand-ruled but holds perfectly still. Cells land on whole device
/// pixels at any scale, so the gaps stay even.
/// </summary>
public sealed class HeatGrid : FrameworkElement
{
    public static readonly DependencyProperty HeatmapProperty = DependencyProperty.Register(
        nameof(Heatmap), typeof(Heatmap), typeof(HeatGrid),
        new FrameworkPropertyMetadata(Heatmap.Empty, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty HoveredProperty = DependencyProperty.Register(
        nameof(Hovered), typeof(HeatmapDay), typeof(HeatGrid),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender | FrameworkPropertyMetadataOptions.BindsTwoWayByDefault));

    public static readonly double[] Levels = [0, 0.16, 0.36, 0.62, 0.92];
    private const double GapRatio = 0.24, MonthRow = 16, Margin_ = 3;

    public HeatGrid()
    {
        Loaded += (_, _) => Palette.Changed += InvalidateVisual;
        Unloaded += (_, _) => Palette.Changed -= InvalidateVisual;
        Background = Brushes.Transparent;
    }

    private Brush Background { get; }

    public Heatmap Heatmap
    {
        get => (Heatmap)GetValue(HeatmapProperty);
        set => SetValue(HeatmapProperty, value);
    }

    public HeatmapDay? Hovered
    {
        get => (HeatmapDay?)GetValue(HoveredProperty);
        set => SetValue(HoveredProperty, value);
    }

    /// <summary>Pitch and cell size in DIPs, both whole device pixels, and the left inset that centers the rest.</summary>
    private (double Pitch, double Cell, double Left) Metrics(double width)
    {
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var n = Math.Max(Heatmap.Weeks.Count, 1);
        var usable = (width - Margin_ * 2) * scale;
        var pitch = Math.Floor(usable / (n - GapRatio));
        var cell = Math.Round(pitch * (1 - GapRatio));
        var used = pitch * (n - 1) + cell;
        var left = Math.Floor((usable - used) / 2);
        return (pitch / scale, cell / scale, Margin_ + left / scale);
    }

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 700 : available.Width;
        var (pitch, cell, _) = Metrics(width);
        return new Size(width, MonthRow + 6 * pitch + cell + Margin_);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var p = Palette.Current;
        dc.DrawRectangle(Background, null, new Rect(RenderSize)); // hit-testable everywhere
        var map = Heatmap;
        var (pitch, cell, left) = Metrics(ActualWidth);
        var today = DateTime.Today;
        var empty = Palette.Brush(Palette.WithAlpha(p.Ink, 0.055));
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;

        // Month labels at each month's first full column, not the half-column at the grid's left edge.
        var lastMonth = -1;
        var face = Segmented.Typeface("Small", FontWeights.Normal);
        for (var w = 0; w < map.Weeks.Count; w++)
        {
            var first = map.Weeks[w].FirstOrDefault(d => d is not null);
            if (first is null) continue;
            if (first.Date.Month == lastMonth) continue;
            if (lastMonth != -1 || first.Date.Day <= 7)
            {
                var label = new FormattedText(Copy.Month(first.Date), CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                                              face, 10, Palette.Brush(p.Faint), dpi);
                dc.DrawText(label, new Point(left + w * pitch, 0));
            }
            lastMonth = first.Date.Month;
        }

        for (var w = 0; w < map.Weeks.Count; w++)
        {
            for (var d = 0; d < 7; d++)
            {
                if (map.Weeks[w][d] is not { } day) continue;
                var r = new Rect(left + w * pitch, MonthRow + d * pitch, cell, cell);
                var square = Doodle.Polygon([r.TopLeft, r.TopRight, r.BottomRight, r.BottomLeft],
                                            unchecked((ulong)(w * 7 + d) * 31 + 7), 0.35);
                dc.DrawGeometry(day.Level > 0 ? Palette.Brush(Palette.WithAlpha(p.Accent, Levels[day.Level])) : empty, null, square);
                var isToday = day.Date == today;
                if (isToday || day == Hovered)
                {
                    var outline = r;
                    outline.Inflate(1.75, 1.75);
                    dc.DrawRoundedRectangle(null, new Pen(Palette.Brush(isToday ? p.Ink : p.Faint), 1.1), outline, 3, 3);
                }
            }
        }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var at = e.GetPosition(this);
        var (pitch, _, left) = Metrics(ActualWidth);
        var w = (int)Math.Floor((at.X - left) / pitch);
        var d = (int)Math.Floor((at.Y - MonthRow) / pitch);
        HeatmapDay? day = null;
        if (at.Y >= MonthRow && w >= 0 && w < Heatmap.Weeks.Count && d is >= 0 and < 7) day = Heatmap.Weeks[w][d];
        if (day != Hovered) Hovered = day;
    }

    protected override void OnMouseLeave(MouseEventArgs e) => Hovered = null;
}

/// <summary>
/// How something stands, in one small mark: a spinner while working, a
/// yellow dot while it waits on you, a green check once it's done. Changes
/// pop, with a little spring.
/// </summary>
public sealed class StatusMark : FrameworkElement
{
    public enum Kind { None, Working, Pending, Done }

    public static readonly DependencyProperty StatusProperty = DependencyProperty.Register(
        nameof(Status), typeof(Kind), typeof(StatusMark), new PropertyMetadata(Kind.None, (d, _) => ((StatusMark)d).Pop()));

    /// <summary>A slow breath on the yellow dot, for waiting on something that'll happen by itself.</summary>
    public bool Breathing { get; set; }

    private static readonly DependencyProperty PopProperty = DependencyProperty.Register(
        "PopScale", typeof(double), typeof(StatusMark), new FrameworkPropertyMetadata(1.0, FrameworkPropertyMetadataOptions.AffectsRender));
    private static readonly DependencyProperty SpinProperty = DependencyProperty.Register(
        "Spin", typeof(double), typeof(StatusMark), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    private static readonly DependencyProperty BreathProperty = DependencyProperty.Register(
        "Breath", typeof(double), typeof(StatusMark), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    private static readonly Color Green = Color.FromRgb(0x2F, 0xA8, 0x4F);
    private static readonly Color Yellow = Color.FromRgb(0xF2, 0xC2, 0x1B);

    public StatusMark()
    {
        Width = Height = 14;
        Loaded += (_, _) => { Palette.Changed += InvalidateVisual; Loop(); };
        Unloaded += (_, _) => Palette.Changed -= InvalidateVisual;
    }

    public Kind Status
    {
        get => (Kind)GetValue(StatusProperty);
        set => SetValue(StatusProperty, value);
    }

    private void Pop()
    {
        if (Status is Kind.Done or Kind.Pending)
            Animate.Settle(this, PopProperty, Status == Kind.Done ? 0.4 : 0.5, 1, 420,
                           new ElasticLikeEase());
        Loop();
    }

    /// <summary>The spinner turns at an even pace; the dot breathes in 1.1s.</summary>
    private void Loop()
    {
        BeginAnimation(SpinProperty, null);
        BeginAnimation(BreathProperty, null);
        if (!Motion.Enabled) return;
        if (Status == Kind.Working)
            BeginAnimation(SpinProperty, new System.Windows.Media.Animation.DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.8))
                { RepeatBehavior = System.Windows.Media.Animation.RepeatBehavior.Forever });
        else if (Status == Kind.Pending && Breathing)
            BeginAnimation(BreathProperty, new System.Windows.Media.Animation.DoubleAnimation(0, 1, TimeSpan.FromSeconds(1.1))
                { RepeatBehavior = System.Windows.Media.Animation.RepeatBehavior.Forever, AutoReverse = true, EasingFunction = BezierEase.InOut });
    }

    protected override void OnRender(DrawingContext dc)
    {
        var s = Math.Min(ActualWidth, ActualHeight);
        var c = new Point(ActualWidth / 2, ActualHeight / 2);
        var pop = (double)GetValue(PopProperty);
        switch (Status)
        {
            case Kind.Working:
            {
                var spin = (double)GetValue(SpinProperty);
                var r = s / 2 - 1;
                var start = spin * Math.PI / 180 - Math.PI / 2;
                var end = start + 0.72 * 2 * Math.PI;
                var g = new StreamGeometry();
                using (var ctx = g.Open())
                {
                    ctx.BeginFigure(new Point(c.X + r * Math.Cos(start), c.Y + r * Math.Sin(start)), false, false);
                    ctx.ArcTo(new Point(c.X + r * Math.Cos(end), c.Y + r * Math.Sin(end)), new Size(r, r), 0, true,
                              SweepDirection.Clockwise, true, false);
                }
                dc.DrawGeometry(null, Doodle.Pen(Palette.Current.Faint, 1.6), g);
                break;
            }
            case Kind.Done:
            {
                var r = s / 2 * pop;
                dc.DrawEllipse(Palette.Brush(Green), null, c, r, r);
                var check = new StreamGeometry();
                using (var ctx = check.Open())
                {
                    ctx.BeginFigure(new Point(c.X - r * 0.42, c.Y + r * 0.02), false, false);
                    ctx.LineTo(new Point(c.X - r * 0.1, c.Y + r * 0.34), true, true);
                    ctx.LineTo(new Point(c.X + r * 0.45, c.Y - r * 0.3), true, true);
                }
                dc.DrawGeometry(null, Doodle.Pen(Colors.White, Math.Max(1.2, r * 0.26)), check);
                break;
            }
            case Kind.Pending:
            {
                var breath = (double)GetValue(BreathProperty);
                var r = 5 * pop * (1 - 0.22 * breath);
                dc.PushOpacity(1 - 0.4 * breath);
                dc.DrawEllipse(Palette.Brush(Yellow), null, c, r, r);
                dc.Pop();
                break;
            }
        }
    }

    /// <summary>spring(response .42, damping .58): a pop with one soft overshoot.</summary>
    private sealed class ElasticLikeEase : System.Windows.Media.Animation.EasingFunctionBase
    {
        public ElasticLikeEase() => EasingMode = System.Windows.Media.Animation.EasingMode.EaseIn;
        protected override double EaseInCore(double t) => 1 - Math.Exp(-6.5 * t) * Math.Cos(7.5 * t);
        protected override Freezable CreateInstanceCore() => new ElasticLikeEase();
    }
}
