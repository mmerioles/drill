using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Media;

namespace Drill.Ink;

/// <summary>
/// Base for drawn ink: redraws on theme changes, and on every boil step
/// while <see cref="Boiling"/> is on and it's on screen.
/// </summary>
public abstract class InkElement : FrameworkElement
{
    public static readonly DependencyProperty BoilingProperty = DependencyProperty.Register(
        nameof(Boiling), typeof(bool), typeof(InkElement),
        new FrameworkPropertyMetadata(false, (d, _) => ((InkElement)d).SyncBoil()));

    public bool Boiling
    {
        get => (bool)GetValue(BoilingProperty);
        set => SetValue(BoilingProperty, value);
    }

    private bool _subscribed;
    private bool _loaded;

    protected InkElement()
    {
        Loaded += (_, _) => { _loaded = true; Palette.Changed += InvalidateVisual; SyncBoil(); };
        Unloaded += (_, _) => { _loaded = false; Palette.Changed -= InvalidateVisual; SyncBoil(); };
        IsVisibleChanged += (_, _) => SyncBoil();
        SnapsToDevicePixels = false;
    }

    /// <summary>Drawn ink is decoration: screen readers skip it (the page names what matters).</summary>
    protected override AutomationPeer OnCreateAutomationPeer() => new HiddenPeer(this);

    /// <summary>The wobble seed for this frame: steps while boiling, still otherwise.</summary>
    protected ulong Seed => _subscribed ? Boil.Seed : 0;

    private void SyncBoil()
    {
        var want = _loaded && IsVisible && Boiling && Motion.Enabled;
        if (want == _subscribed) return;
        _subscribed = want;
        if (want) Boil.Subscribe(InvalidateVisual); else Boil.Unsubscribe(InvalidateVisual);
        InvalidateVisual();
    }
}

/// <summary>A peer that keeps an element out of what screen readers see.</summary>
public sealed class HiddenPeer(FrameworkElement owner) : FrameworkElementAutomationPeer(owner)
{
    protected override bool IsControlElementCore() => false;
    protected override bool IsContentElementCore() => false;
    protected override List<AutomationPeer>? GetChildrenCore() => null;
}

/// <summary>
/// The timer's face: a dotted pencil track with an inked arc drawn over it
/// clockwise from twelve o'clock, and a pen-tip dot where the ink stops.
/// </summary>
public sealed class DoodleRing : InkElement
{
    public static readonly DependencyProperty ProgressProperty = DependencyProperty.Register(
        nameof(Progress), typeof(double), typeof(DoodleRing),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty LineWidthProperty = DependencyProperty.Register(
        nameof(LineWidth), typeof(double), typeof(DoodleRing),
        new FrameworkPropertyMetadata(2.6, FrameworkPropertyMetadataOptions.AffectsRender));

    public double Progress
    {
        get => (double)GetValue(ProgressProperty);
        set => SetValue(ProgressProperty, value);
    }

    public double LineWidth
    {
        get => (double)GetValue(LineWidthProperty);
        set => SetValue(LineWidthProperty, value);
    }

    private static readonly DashStyle Dotted = Freeze(new DashStyle([1.5 / 1.4, 6 / 1.4], 0));

    protected override void OnRender(DrawingContext dc)
    {
        Draw(dc, new Size(ActualWidth, ActualHeight), Progress, LineWidth, Seed, Palette.Current);
    }

    /// <summary>Shared with the tray icon, which draws the same ring small.</summary>
    public static void Draw(DrawingContext dc, Size size, double progress, double lineWidth, ulong tick, Palette p,
                            Color? track = null, Color? ink = null, double trackWidth = 1.4, bool dotted = true,
                            bool tip = true)
    {
        var c = new Point(size.Width / 2, size.Height / 2);
        var r = Math.Min(size.Width, size.Height) / 2 - lineWidth * 2;
        if (r <= 0) return;
        const int samples = 72;

        Point At(int i, int n, double sweep)
        {
            var a = -Math.PI / 2 + sweep * i / n;
            return new Point(c.X + Math.Cos(a) * r, c.Y + Math.Sin(a) * r);
        }

        var trackPts = Enumerable.Range(0, samples).Select(i => At(i, samples, 2 * Math.PI)).ToArray();
        if (track is not { A: 0 })
            dc.DrawGeometry(null, Doodle.Pen(track ?? p.Ghost, trackWidth, dotted ? Dotted : null),
                        Doodle.Path(Doodle.Jitter(trackPts, unchecked(tick + 3), 0.7 * Scale(r)), closed: true));

        var prog = Math.Clamp(progress, 0, 1);
        if (prog <= 0.001) return;
        var n = Math.Max(2, (int)(samples * prog));
        var arc = Doodle.Jitter(Enumerable.Range(0, n + 1).Select(i => At(i, n, 2 * Math.PI * prog)).ToArray(),
                                unchecked(tick + 17), 0.9 * Scale(r));
        var color = ink ?? p.Accent;
        dc.DrawGeometry(null, Doodle.Pen(color, lineWidth), Doodle.Path(arc, closed: false));

        if (!tip) return;
        var d = lineWidth * 2.4;
        dc.DrawEllipse(Palette.Brush(color), null, arc[^1], d / 2, d / 2);
    }

    /// <summary>The wobble is tuned for the 270pt ring; small rings wobble less.</summary>
    private static double Scale(double r) => Math.Clamp(r / 125, 0.25, 1);

    private static DashStyle Freeze(DashStyle s)
    {
        s.Freeze();
        return s;
    }
}
