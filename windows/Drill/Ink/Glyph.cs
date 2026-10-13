using System.Windows;
using System.Windows.Media;

namespace Drill.Ink;

public enum GlyphKind { Drill, Baguette, Check }

/// <summary>
/// Small hand-drawn marks, as in Sources/InkKit/Glyphs.swift. The Teto nods
/// live here: her drill twintail for focus, a baguette for breaks — never a
/// face, never a colour.
/// </summary>
public sealed class Glyph : InkElement
{
    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(
        nameof(Kind), typeof(GlyphKind), typeof(Glyph),
        new FrameworkPropertyMetadata(GlyphKind.Drill, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty LineWidthProperty = DependencyProperty.Register(
        nameof(LineWidth), typeof(double), typeof(Glyph),
        new FrameworkPropertyMetadata(1.6, FrameworkPropertyMetadataOptions.AffectsRender));

    /// <summary>Accent instead of ink: the logo's crimson in light.</summary>
    public static readonly DependencyProperty AccentProperty = DependencyProperty.Register(
        nameof(Accent), typeof(bool), typeof(Glyph),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));

    public GlyphKind Kind
    {
        get => (GlyphKind)GetValue(KindProperty);
        set => SetValue(KindProperty, value);
    }

    public double LineWidth
    {
        get => (double)GetValue(LineWidthProperty);
        set => SetValue(LineWidthProperty, value);
    }

    public bool Accent
    {
        get => (bool)GetValue(AccentProperty);
        set => SetValue(AccentProperty, value);
    }

    protected override Size MeasureOverride(Size available) => new(Width.IsNaN() ? 22 : Width, Height.IsNaN() ? 22 : Height);

    protected override void OnRender(DrawingContext dc)
    {
        var p = Palette.Current;
        Draw(dc, Kind, Math.Min(ActualWidth, ActualHeight), LineWidth, Seed, Accent ? p.Accent : p.Ink);
    }

    public static void Draw(DrawingContext dc, GlyphKind kind, double s, double lineWidth, ulong tick, Color tint, double roughness = 1)
    {
        var pen = Doodle.Pen(tint, lineWidth);
        var amp = s / 60 * roughness;
        switch (kind)
        {
            case GlyphKind.Drill:
                dc.DrawGeometry(null, pen, DrillPath(s, unchecked(tick + 5), amp));
                break;
            case GlyphKind.Baguette:
                foreach (var g in Baguette(s, unchecked(tick + 9), amp)) dc.DrawGeometry(null, pen, g);
                break;
            case GlyphKind.Check:
                var pts = Doodle.Jitter([new(0.18 * s, 0.52 * s), new(0.42 * s, 0.76 * s), new(0.84 * s, 0.24 * s)],
                                       unchecked(tick + 13), amp);
                var check = new StreamGeometry();
                using (var ctx = check.Open())
                {
                    ctx.BeginFigure(pts[0], false, false);
                    ctx.PolyLineTo(pts[1..], true, true);
                }
                check.Freeze();
                dc.DrawGeometry(null, pen, check);
                break;
        }
    }

    /// <summary>
    /// A tapering corkscrew: a spring seen slightly from above, wide at the
    /// root and narrowing to a point — reads as a drill curl at any size.
    /// </summary>
    public static StreamGeometry DrillPath(double s, ulong seed, double amp)
    {
        const double turns = 3.4;
        // Sparse samples (~10 a turn) with wobble that shrinks toward the
        // tip: dense, evenly jittered points bead up where the coil is tight.
        const int steps = 36;
        var w = new Wobble(seed);
        var pts = new Point[steps + 1];
        for (var i = 0; i <= steps; i++)
        {
            var t = (double)i / steps;
            var angle = t * turns * 2 * Math.PI;
            var radius = s * (0.30 * (1 - t) + 0.04);
            var y = s * (0.10 + 0.78 * t) + Math.Sin(angle) * radius * 0.32;
            var a = amp * 0.6 * (1 - 0.7 * t) * 2;
            var x = s * 0.5 + Math.Cos(angle) * radius + w.Next() * a;
            pts[i] = new Point(x, y + w.Next() * a);
        }
        return Doodle.Path(pts, closed: false);
    }

    /// <summary>A loaf tilted on the diagonal with three scores across its back.</summary>
    public static List<Geometry> Baguette(double s, ulong seed, double amp)
    {
        var c = new Point(s / 2, s / 2);
        const double angle = -Math.PI / 4;
        Point Rotate(double x, double y) =>
            new(c.X + x * Math.Cos(angle) - y * Math.Sin(angle), c.Y + x * Math.Sin(angle) + y * Math.Cos(angle));
        double half = s * 0.44, thick = s * 0.13;
        var outline = new List<Point>();
        for (var i = 0; i < 12; i++)
        {
            var a = -Math.PI / 2 + i / 11.0 * Math.PI;
            outline.Add(Rotate(half - thick + Math.Cos(a) * thick, Math.Sin(a) * thick));
        }
        for (var i = 0; i < 12; i++)
        {
            var a = Math.PI / 2 + i / 11.0 * Math.PI;
            outline.Add(Rotate(-half + thick + Math.Cos(a) * thick, Math.Sin(a) * thick));
        }
        var paths = new List<Geometry> { Doodle.Path(Doodle.Jitter(outline, seed, amp * 0.5), closed: true) };
        var w = new Wobble(unchecked(seed + 1));
        foreach (var x in new[] { -0.45, 0.0, 0.45 })
        {
            var dx = x * half;
            var line = new LineGeometry(Rotate(dx - thick * 0.35 + w.Next() * amp, -thick * 0.45),
                                        Rotate(dx + thick * 0.35 + w.Next() * amp, thick * 0.45));
            line.Freeze();
            paths.Add(line);
        }
        return paths;
    }
}

internal static class DoubleExtensions
{
    public static bool IsNaN(this double d) => double.IsNaN(d);
}
