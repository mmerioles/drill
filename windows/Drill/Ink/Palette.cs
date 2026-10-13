using System.Windows;
using System.Windows.Media;

namespace Drill.Ink;

/// <summary>light is the teto palette, dark is pure ink.</summary>
public enum Theme { Light, Dark }

/// <summary>
/// drill's look, as in Sources/InkKit/Ink.swift: paper, one ink, lots of
/// air, lowercase sentences, hand-drawn strokes that "boil" gently.
///
///   dark  — "ink":  pure monochrome, white ink on black. The accent is just ink.
///   light — "teto": off-white paper, charcoal ink, and Teto's crimson as the
///           one accent — used only for progress (ring, heatmap, logo).
///
/// XAML reads these as DynamicResources by key ("Paper", "Ink", …); drawn
/// controls read <see cref="Current"/> and redraw on <see cref="Changed"/>.
/// </summary>
public sealed class Palette
{
    public required Theme Theme { get; init; }
    public required Color Paper { get; init; }
    public required Color Ink { get; init; }
    public required Color Accent { get; init; }
    /// <summary>Dialog cards: paper, lifted in dark so it reads above the smoke.</summary>
    public required Color Raised { get; init; }
    /// <summary>The scrim behind dialogs.</summary>
    public required Color Smoke { get; init; }

    /// <summary>Secondary text and idle strokes.</summary>
    public Color Faint => WithAlpha(Ink, 0.45);
    /// <summary>Hairlines, empty cells, tracks.</summary>
    public Color Ghost => WithAlpha(Ink, 0.12);

    public static readonly Palette Light = new()
    {
        Theme = Theme.Light,
        Paper = Hex(0xF2F0ED), Ink = Hex(0x2B2A2F), Accent = Hex(0xCF3A4F),
        Raised = Hex(0xF2F0ED), Smoke = Color.FromArgb(0x4D, 0, 0, 0),
    };

    public static readonly Palette Dark = new()
    {
        Theme = Theme.Dark,
        Paper = Hex(0x121211), Ink = Hex(0xF1F0EB), Accent = Hex(0xF1F0EB),
        Raised = Hex(0x1C1C1B), Smoke = Color.FromArgb(0x80, 0, 0, 0),
    };

    public static Palette Current { get; private set; } = Dark;

    public static event Action? Changed;

    public static Palette For(Theme theme) => theme == Theme.Light ? Light : Dark;

    /// <summary>Re-themes every window at once.</summary>
    public static void Apply(Theme theme, ResourceDictionary resources)
    {
        var p = For(theme);
        Current = p;
        resources["Paper"] = Brush(p.Paper);
        resources["Ink"] = Brush(p.Ink);
        resources["Accent"] = Brush(p.Accent);
        resources["Faint"] = Brush(p.Faint);
        resources["Ghost"] = Brush(p.Ghost);
        resources["Raised"] = Brush(p.Raised);
        resources["Smoke"] = Brush(p.Smoke);
        // Placeholder text, quieter than faint.
        resources["Hint"] = Brush(WithAlpha(p.Ink, 0.28));
        // Settings cards: a tint of ink, and an outline lighter than ghost.
        resources["CardFill"] = Brush(WithAlpha(p.Ink, theme == Theme.Light ? 0.04 : 0.06));
        resources["CardLine"] = Brush(WithAlpha(p.Ink, 0.08));
        resources["Hover"] = Brush(WithAlpha(p.Ink, 0.06));
        resources["Press"] = Brush(WithAlpha(p.Ink, 0.04));
        resources["Border"] = Brush(WithAlpha(p.Ink, 0.10));
        // Empty heatmap days: a faint wash, quieter than an outline at 365 cells.
        resources["Empty"] = Brush(WithAlpha(p.Ink, 0.055));
        Changed?.Invoke();
    }

    public static Color Hex(uint rgb) => Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    public static Color WithAlpha(Color c, double alpha) => Color.FromArgb((byte)Math.Round(alpha * 255), c.R, c.G, c.B);

    public static SolidColorBrush Brush(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}
