import SwiftUI

/// The one primary action per screen: an ink capsule with paper text.
public struct InkCapsuleStyle: ButtonStyle {
    var size: CGFloat
    var minWidth: CGFloat?

    /// `minWidth` keeps the capsule steady when its label changes, e.g.
    /// start → pause.
    public init(size: CGFloat = 16, minWidth: CGFloat? = nil) {
        self.size = size
        self.minWidth = minWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ink.text(size, .semibold))
            .foregroundStyle(Ink.paper)
            .padding(.horizontal, size * 2.6)
            .frame(minWidth: minWidth)
            .padding(.vertical, size * 0.85)
            .background(Capsule().fill(Ink.ink))
            .modifier(HoverFade())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Ink.snap, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Everything secondary: faint lowercase words that darken under the pointer.
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
            .modifier(LinkInk(selected: selected))
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

/// Faint at rest, full ink when hovered or selected.
private struct LinkInk: ViewModifier {
    var selected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected || hovered ? Ink.ink : Ink.faint)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Fades its content slightly while the pointer is over it.
private struct HoverFade: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .opacity(hovered ? 0.86 : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
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
