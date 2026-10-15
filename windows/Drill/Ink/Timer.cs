using System.Globalization;
using System.Windows;
using System.Windows.Automation.Peers;
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

    /// <summary>A new size redraws the digits at it (the ring grows with the window).</summary>
    protected override void OnPropertyChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.Property == FontSizeProperty && _cells.Count > 0) Rebuild(Text);
    }

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
        // A different shape (25:00 → 1:00:00): rebuild without a roll. Off
        // screen (the window hidden in the tray), nothing animates either.
        if (old.Length != text.Length || _cells.Count != text.Length || !Motion.Enabled || !IsLoaded || !IsVisible)
        {
            Rebuild(text);
            return;
        }
        for (var i = 0; i < text.Length; i++)
        {
            if (old[i] != text[i]) Roll(_cells[i], text[i]);
        }
    }

    /// <summary>
    /// One piece of text to screen readers, not a run of single digits. Its
    /// name is AutomationProperties.Name when set ("focus, 12 minutes left"),
    /// else the digits.
    /// </summary>
    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    private sealed class Peer(RollingText owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
        protected override string GetClassNameCore() => "RollingText";
        protected override List<AutomationPeer>? GetChildrenCore() => null;
        protected override string GetNameCore() => base.GetNameCore() is { Length: > 0 } name ? name : owner.Text;
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

    /// <summary>Decorative: the cycle isn't read out.</summary>
    protected override AutomationPeer OnCreateAutomationPeer() => new HiddenPeer(this);

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
        new FrameworkPropertyMetadata(Heatmap.Empty, FrameworkPropertyMetadataOptions.AffectsRender | FrameworkPropertyMetadataOptions.AffectsMeasure));

    public static readonly DependencyProperty HoveredProperty = DependencyProperty.Register(
        nameof(Hovered), typeof(HeatmapDay), typeof(HeatGrid),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender, (d, _) => ((HeatGrid)d).HoveredChanged?.Invoke()));

    /// <summary>The day under the pointer changed.</summary>
    public event Action? HoveredChanged;

    public static readonly double[] Levels = [0, 0.16, 0.36, 0.62, 0.92];
    /// <summary>Square cells 2 apart, 11 to 14 across; month labels (12) in a row 6 above the cells.</summary>
    private const double Gap = 2, CellMin = 11, CellMax = 14, MonthRow = 22, Margin_ = 3;

    /// <summary>
    /// The cells and month labels, drawn once per heatmap, width, scale and
    /// palette; a hover only adds an outline on top.
    /// </summary>
    private (Heatmap Map, double Width, double Scale, Palette Palette, DrawingGroup Drawing)? _drawn;
    private (Palette Palette, Brush[] Brushes)? _brushes;
    /// <summary>Where the hovered day is in the grid.</summary>
    private (int Week, int Day) _hoverAt = (-1, -1);

    public HeatGrid()
    {
        Loaded += (_, _) => Palette.Changed += InvalidateVisual;
        Unloaded += (_, _) => Palette.Changed -= InvalidateVisual;
    }

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

    /// <summary>A picture to screen readers, named by the page with the year's summary.</summary>
    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    private sealed class Peer(HeatGrid owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Image;
        protected override string GetClassNameCore() => "HeatGrid";
        protected override List<AutomationPeer>? GetChildrenCore() => null;
    }

    /// <summary>
    /// The exact pitch (cell + gap), and the cell size in whole device pixels:
    /// the width shared by the weeks with 2 between, kept between 11 and 14.
    /// Each column is placed by <see cref="Column"/>, rounded on its own, so the
    /// grid's outer edges land exactly on the content's and gaps differ by at
    /// most a pixel.
    /// </summary>
    private (double Pitch, double Cell) Metrics(double width, double scale)
    {
        var n = Math.Max(Heatmap.Weeks.Count, 1);
        var cell = Math.Clamp((width - Margin_ * 2 - (n - 1) * Gap) / n, CellMin, CellMax);
        return (cell + Gap, Math.Round(cell * scale) / scale);
    }

    private static double Column(int w, double pitch, double scale) => Snap(Margin_ + w * pitch, scale);
    private static double Row(int d, double pitch, double scale) => Snap(MonthRow + d * pitch, scale);
    private static double Snap(double dip, double scale) => Math.Round(dip * scale) / scale;

    private double Scale => VisualTreeHelper.GetDpi(this).DpiScaleX;

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 706 : available.Width;
        var (pitch, cell) = Metrics(width, Scale);
        return new Size(width, MonthRow + 6 * pitch + cell + Margin_);
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        InvalidateMeasure();
        InvalidateVisual();
    }

    /// <summary>The five fills, made once per palette.</summary>
    private Brush[] LevelBrushes(Palette p)
    {
        if (_brushes is { } b && b.Palette == p) return b.Brushes;
        var brushes = new Brush[Levels.Length];
        brushes[0] = Palette.Brush(Palette.WithAlpha(p.Ink, 0.055));
        for (var i = 1; i < Levels.Length; i++) brushes[i] = Palette.Brush(Palette.WithAlpha(p.Accent, Levels[i]));
        _brushes = (p, brushes);
        return brushes;
    }

    protected override void OnRender(DrawingContext dc)
    {
        var p = Palette.Current;
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize)); // hit-testable everywhere
        var map = Heatmap;
        var scale = Scale;
        var width = ActualWidth;
        if (_drawn is not { } d || d.Map != map || d.Width != width || d.Scale != scale || d.Palette != p)
        {
            d = (map, width, scale, p, Cells(map, width, scale, p));
            _drawn = d;
        }
        dc.DrawDrawing(d.Drawing);

        var (w, day) = _hoverAt;
        if (Hovered is { } hovered && w >= 0 && w < map.Weeks.Count && day is >= 0 and < 7 && map.Weeks[w][day] == hovered)
        {
            var (pitch, cell) = Metrics(width, scale);
            var outline = new Rect(Column(w, pitch, scale), Row(day, pitch, scale), cell, cell);
            outline.Inflate(1.75, 1.75);
            var isToday = w == map.Weeks.Count - 1 && map.Weeks[w].LastOrDefault(x => x is not null) == hovered;
            if (!isToday) dc.DrawRoundedRectangle(null, new Pen(Palette.Brush(p.Faint), 1.1), outline, 2.5, 2.5);
        }
    }

    /// <summary>Every cell (each wobbling by its own fixed seed), today's outline, and the month labels.</summary>
    private DrawingGroup Cells(Heatmap map, double width, double scale, Palette p)
    {
        var group = new DrawingGroup();
        using (var dc = group.Open())
        {
            var (pitch, cell) = Metrics(width, scale);
            // Today is the grid's last day, whatever this machine's clock says.
            var today = map.Weeks.Count > 0 ? map.Weeks[^1].LastOrDefault(d => d is not null)?.Date : null;
            var brushes = LevelBrushes(p);
            var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;

            // Month labels at each month's first full column, not the half-column at the grid's left edge.
            var lastMonth = -1;
            var face = Segmented.Typeface("Small", FontWeights.Normal);
            var faint = Palette.Brush(p.Faint);
            for (var w = 0; w < map.Weeks.Count; w++)
            {
                var first = map.Weeks[w].FirstOrDefault(d => d is not null);
                if (first is null) continue;
                if (first.Date.Month == lastMonth) continue;
                if (lastMonth != -1 || first.Date.Day <= 7)
                {
                    var label = new FormattedText(Copy.Month(first.Date), CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                                                  face, 12, faint, dpi);
                    dc.DrawText(label, new Point(Column(w, pitch, scale), 0));
                }
                lastMonth = first.Date.Month;
            }

            for (var w = 0; w < map.Weeks.Count; w++)
            {
                for (var d = 0; d < 7; d++)
                {
                    if (map.Weeks[w][d] is not { } day) continue;
                    var r = new Rect(Column(w, pitch, scale), Row(d, pitch, scale), cell, cell);
                    var square = Doodle.Polygon([r.TopLeft, r.TopRight, r.BottomRight, r.BottomLeft],
                                                unchecked((ulong)(w * 7 + d) * 31 + 7), 0.35);
                    dc.DrawGeometry(brushes[Math.Clamp(day.Level, 0, brushes.Length - 1)], null, square);
                    if (day.Date == today)
                    {
                        var outline = r;
                        outline.Inflate(1.75, 1.75);
                        dc.DrawRoundedRectangle(null, new Pen(Palette.Brush(p.Ink), 1.5), outline, 2.5, 2.5);
                    }
                }
            }
        }
        group.Freeze();
        return group;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var at = e.GetPosition(this);
        var (pitch, _) = Metrics(ActualWidth, Scale);
        var w = (int)Math.Floor((at.X - Margin_) / pitch);
        var d = (int)Math.Floor((at.Y - MonthRow) / pitch);
        HeatmapDay? day = null;
        if (at.Y >= MonthRow && w >= 0 && w < Heatmap.Weeks.Count && d is >= 0 and < 7) day = Heatmap.Weeks[w][d];
        _hoverAt = day is null ? (-1, -1) : (w, d);
        if (day != Hovered) Hovered = day;
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        _hoverAt = (-1, -1);
        Hovered = null;
    }
}

/// <summary>
/// How something stands, in one small mark: a spinner while working, a
/// yellow dot while it waits on you, a green check once it's done, a red
/// cross when it failed. Changes pop, with a little spring.
/// </summary>
public sealed class StatusMark : FrameworkElement
{
    public enum Kind { None, Working, Pending, Done, Failed }

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

    private static readonly Color Yellow = Color.FromRgb(0xF2, 0xC2, 0x1B);
    /// <summary>The light palette's crimson: dark's accent is ink, and a cross should read as a no.</summary>
    private static readonly Color Red = Palette.Light.Accent;

    /// <summary>Decorative: the note beside it says the same in words.</summary>
    protected override AutomationPeer OnCreateAutomationPeer() => new HiddenPeer(this);

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
        if (Status is Kind.Done or Kind.Pending or Kind.Failed)
            Animate.Settle(this, PopProperty, Status == Kind.Pending ? 0.5 : 0.4, 1, 420,
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
                dc.DrawEllipse(Palette.Brush(Palette.Current.Ok), null, c, r, r);
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
            case Kind.Failed:
            {
                var r = s / 2 * pop;
                dc.DrawEllipse(Palette.Brush(Red), null, c, r, r);
                var pen = Doodle.Pen(Colors.White, Math.Max(1.2, r * 0.26));
                var d = r * 0.36;
                dc.DrawLine(pen, new Point(c.X - d, c.Y - d), new Point(c.X + d, c.Y + d));
                dc.DrawLine(pen, new Point(c.X - d, c.Y + d), new Point(c.X + d, c.Y - d));
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
