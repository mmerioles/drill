import SwiftUI

/// The one primary action per screen: an ink capsule with paper text.
public struct InkCapsuleStyle: ButtonStyle {
    var size: CGFloat

    public init(size: CGFloat = 16) { self.size = size }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ink.text(size, .semibold))
            .foregroundStyle(Ink.paper)
            .padding(.horizontal, size * 2.6)
            .padding(.vertical, size * 0.85)
            .background(Capsule().fill(Ink.ink))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Ink.snap, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Everything secondary: faint, underlined lowercase words.
public struct InkLinkStyle: ButtonStyle {
    var size: CGFloat
    var selected: Bool

    public init(size: CGFloat = 14, selected: Bool = false) {
        self.size = size
        self.selected = selected
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ink.text(size, selected ? .semibold : .regular))
            .foregroundStyle(selected ? Ink.ink : Ink.faint)
            .underline(!selected)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == InkCapsuleStyle {
    static var inkCapsule: InkCapsuleStyle { InkCapsuleStyle() }
}

public extension ButtonStyle where Self == InkLinkStyle {
    static var inkLink: InkLinkStyle { InkLinkStyle() }
    static func inkLink(selected: Bool, size: CGFloat = 14) -> InkLinkStyle {
        InkLinkStyle(size: size, selected: selected)
    }
}
