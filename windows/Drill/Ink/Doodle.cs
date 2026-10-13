using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace Drill.Ink;

// Doodle machinery, as in Sources/InkKit/Doodle.swift. Every stroke is
// jittered by a seeded wobble, and the seed steps every 0.4s — the classic
// hand-drawn "boil". Amplitude stays around a point so it reads as pen
// texture in motion, not noise.

public struct Wobble(ulong seed)
{
    private ulong _seed = seed;

    /// <summary>Next value in -0.5..&lt;0.5.</summary>
    public double Next()
    {
        unchecked { _seed = _seed * 6364136223846793005UL + 1442695040888963407UL; }
        return (double)((_seed >> 33) % 1000) / 1000 - 0.5;
    }
}

public static class Doodle
{
    public static Point[] Jitter(IReadOnlyList<Point> pts, ulong seed, double amp = 1.2)
    {
        var w = new Wobble(seed);
        var out_ = new Point[pts.Count];
        for (var i = 0; i < pts.Count; i++)
        {
            var dx = w.Next() * amp * 2;
            var dy = w.Next() * amp * 2;
            out_[i] = new Point(pts[i].X + dx, pts[i].Y + dy);
        }
        return out_;
    }

    /// <summary>
    /// A soft curve through `pts`. Closed paths run midpoint to midpoint all
    /// the way around, so the seam lands mid-curve and never shows a corner.
    /// Frozen, so it can be drawn from any frame for free.
    /// </summary>
    public static StreamGeometry Path(IReadOnlyList<Point> pts, bool closed)
    {
        var g = new StreamGeometry();
        if (pts.Count > 1)
        {
            using var ctx = g.Open();
            static Point Mid(Point a, Point b) => new((a.X + b.X) / 2, (a.Y + b.Y) / 2);
            if (closed)
            {
                var n = pts.Count;
                ctx.BeginFigure(Mid(pts[n - 1], pts[0]), isFilled: false, isClosed: true);
                for (var i = 0; i < n; i++)
                    ctx.QuadraticBezierTo(pts[i], Mid(pts[i], pts[(i + 1) % n]), isStroked: true, isSmoothJoin: true);
            }
            else
            {
                ctx.BeginFigure(pts[0], isFilled: false, isClosed: false);
                for (var i = 1; i < pts.Count; i++)
                    ctx.QuadraticBezierTo(pts[i - 1], Mid(pts[i - 1], pts[i]), isStroked: true, isSmoothJoin: true);
                ctx.LineTo(pts[^1], isStroked: true, isSmoothJoin: true);
            }
        }
        g.Freeze();
        return g;
    }

    /// <summary>A polygon whose edges wobble but whose corners stay corners.</summary>
    public static StreamGeometry Polygon(IReadOnlyList<Point> corners, ulong seed, double amp = 1.0)
    {
        var samples = new List<Point>(corners.Count * 3);
        for (var i = 0; i < corners.Count; i++)
        {
            var a = corners[i];
            var b = corners[(i + 1) % corners.Count];
            for (var t = 0; t < 3; t++)
            {
                var f = t / 3.0;
                samples.Add(new Point(a.X + (b.X - a.X) * f, a.Y + (b.Y - a.Y) * f));
            }
        }
        var pts = Jitter(samples, seed, amp);
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            ctx.BeginFigure(pts[0], isFilled: true, isClosed: true);
            ctx.PolyLineTo(pts[1..], isStroked: false, isSmoothJoin: false);
        }
        g.Freeze();
        return g;
    }

    public static Pen Pen(Color color, double width, DashStyle? dash = null)
    {
        var pen = new Pen(Palette.Brush(color), width)
        {
            StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round,
            LineJoin = PenLineJoin.Round, DashCap = PenLineCap.Round,
        };
        if (dash is not null) pen.DashStyle = dash;
        pen.Freeze();
        return pen;
    }
}

/// <summary>
/// The one clock every boiling stroke shares: a seed that steps every 0.4s,
/// as discrete frames — nothing tweens and nothing draws per frame. It only
/// runs while something is boiling, and holds still when Windows' animation
/// effects are off.
/// </summary>
public static class Boil
{
    public const double Step = 0.4;
    private static readonly DispatcherTimer Timer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(Step) };
    private static int _subscribers;
    private static event Action? Ticked;

    static Boil() => Timer.Tick += (_, _) => Ticked?.Invoke();

    /// <summary>The current seed: whole steps since the epoch.</summary>
    public static ulong Seed => Motion.Enabled ? (ulong)(DateTime.UtcNow.Ticks / (long)(Step * TimeSpan.TicksPerSecond)) : 0;

    public static void Subscribe(Action redraw)
    {
        Ticked += redraw;
        if (++_subscribers == 1) Timer.Start();
    }

    public static void Unsubscribe(Action redraw)
    {
        Ticked -= redraw;
        if (--_subscribers <= 0)
        {
            _subscribers = 0;
            Timer.Stop();
        }
    }
}

/// <summary>Whether to animate: Windows' "animation effects" setting.</summary>
public static class Motion
{
    private static bool? _enabled;

    public static bool Enabled => _enabled ??= Read();

    /// <summary>Forgets the cached answer, after a settings change.</summary>
    public static void Refresh() => _enabled = null;

    /// <summary>For --render: still frames.</summary>
    public static void Disable() => _enabled = false;

    private static bool Read()
    {
        try
        {
            if (!SystemParameters.ClientAreaAnimation) return false;
            return new Windows.UI.ViewManagement.UISettings().AnimationsEnabled;
        }
        catch (Exception)
        {
            return SystemParameters.ClientAreaAnimation;
        }
    }
}
