import SwiftUI

// Paper, one ink, hand-drawn strokes that "boil". Two themes by appearance:
// dark is pure monochrome; light is Teto's palette, with her crimson as the
// one accent, used only for progress (ring, heatmap, logo).

public enum Ink {
    public static let paper = Color(light: 0xF2F0ED, dark: 0x121211)
    public static let ink = Color(light: 0x2B2A2F, dark: 0xF1F0EB)
    /// Progress and identity marks. Teto crimson in light, plain ink in dark.
    public static let accent = Color(light: 0xCF3A4F, dark: 0xF1F0EB)
    /// The one green: a check that something is fine.
    public static let ok = Color(light: 0x3B9B5E, dark: 0x5FBF80)
    /// Secondary text and idle strokes.
    public static let faint = ink.opacity(0.45)
    /// Hairlines, empty cells, tracks.
    public static let ghost = ink.opacity(0.12)

    public static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Wordmark and headline weight.
    public static func word(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold)
    }

    public static func digits(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold).monospacedDigit()
    }

    public static let ease = Animation.easeOut(duration: 0.5)
    public static let snap = Animation.spring(response: 0.3, dampingFraction: 0.8)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
