import SwiftUI

/// Small hand-drawn marks: Teto's drill twintail (the logo), a check, and a
/// tomato and stopwatch for the timer's two modes.
public struct Glyph: View {
    public enum Kind: Hashable, Sendable { case drill, check, tomato, stopwatch }

    let kind: Kind
    var size: CGFloat
    var boiling: Bool
    var lineWidth: CGFloat
    var tint: Color
    var roughness: Double

    /// `roughness` scales the hand wobble; drop it for large renders, where
    /// the wobble would otherwise grow with the glyph.
    public init(_ kind: Kind, size: CGFloat = 22, boiling: Bool = true, lineWidth: CGFloat = 1.6,
                tint: Color = Ink.ink, roughness: Double = 1) {
        self.kind = kind
        self.size = size
        self.boiling = boiling
        self.lineWidth = lineWidth
        self.tint = tint
        self.roughness = roughness
    }

    public var body: some View {
        Boil(active: boiling) { tick in
            Canvas { ctx, cs in
                let s = min(cs.width, cs.height)
                let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                let amp = Double(s) / 60 * roughness
                switch kind {
                case .drill:
                    ctx.stroke(Self.drill(s, seed: tick &+ 5, amp: amp), with: .color(tint), style: style)
                case .check:
                    let pts = Doodle.jitter(
                        [CGPoint(x: 0.18 * s, y: 0.52 * s), CGPoint(x: 0.42 * s, y: 0.76 * s),
                         CGPoint(x: 0.84 * s, y: 0.24 * s)], seed: tick &+ 13, amp: amp)
                    var p = Path()
                    p.addLines(pts)
                    ctx.stroke(p, with: .color(tint), style: style)
                case .tomato:
                    for path in Self.tomato(s, seed: tick &+ 21, amp: amp) {
                        ctx.stroke(path, with: .color(tint), style: style)
                    }
                case .stopwatch:
                    for path in Self.stopwatch(s, seed: tick &+ 29, amp: amp) {
                        ctx.stroke(path, with: .color(tint), style: style)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        // Decoration: the words beside a glyph already say what it means.
        .accessibilityHidden(true)
    }

    /// A tapering corkscrew: a spring seen slightly from above, wide at the
    /// root and narrowing to a point — reads as a drill curl at any size.
    private static func drill(_ s: CGFloat, seed: UInt64, amp: Double) -> Path {
        let turns = 3.4
        // Sparse samples (~10 a turn) with wobble that shrinks toward the
        // tip: dense, evenly jittered points bead up where the coil is tight.
        let steps = 36
        var w = Wobble(seed: seed)
        let pts = (0...steps).map { i -> CGPoint in
            let t = Double(i) / Double(steps)
            let angle = t * turns * 2 * .pi
            let radius = Double(s) * (0.30 * (1 - t) + 0.04)
            let y = Double(s) * (0.10 + 0.78 * t) + sin(angle) * radius * 0.32
            let a = amp * 0.6 * (1 - 0.7 * t) * 2
            return CGPoint(x: Double(s) * 0.5 + cos(angle) * radius + w.next() * a, y: y + w.next() * a)
        }
        return Doodle.path(pts, closed: false)
    }

    /// The pomodoro: a round fruit under a star-shaped calyx. The drawing
    /// is IconPark's "tomato" (Apache 2.0, © ByteDance; see
    /// THIRD_PARTY_NOTICES.md), on its 48-unit grid, with drill's wobble on
    /// every point so it boils like the rest of the ink.
    private static func tomato(_ s: CGFloat, seed: UInt64, amp: Double) -> [Path] {
        let k = s / 48
        var w = Wobble(seed: seed)
        // A little less wobble than the hand-drawn marks: it's already a drawing.
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x * k + w.next() * amp * 0.8, y: y * k + w.next() * amp * 0.8)
        }

        // The fruit, notched at the top where the calyx sits.
        var fruit = Path()
        fruit.move(to: p(24, 44))
        fruit.addCurve(to: p(44, 27.5), control1: p(35.046, 44), control2: p(44, 36.613))
        fruit.addCurve(to: p(33, 12.984), control1: p(44, 21.058), control2: p(39.525, 15.701))
        for (x, y) in [(29.5, 14.5), (30, 20), (23.5, 18), (17, 20), (17, 14.5), (14, 12.984)] {
            fruit.addLine(to: p(x, y))
        }
        fruit.addCurve(to: p(4, 27.5), control1: p(8.022, 15.837), control2: p(4, 21.393))
        fruit.addCurve(to: p(24, 44), control1: p(4, 36.613), control2: p(12.954, 44))
        fruit.closeSubpath()

        // The five-pointed calyx.
        let star = [(23.5, 4.0), (27.309, 9.117), (36, 9.91), (29.663, 14.483), (31.5, 21),
                    (23.5, 18), (15.5, 21), (17.337, 14.483), (11, 9.91), (19.691, 9.117)]
        var calyx = Path()
        calyx.addLines(star.map { p($0.0, $0.1) })
        calyx.closeSubpath()
        return [fruit, calyx]
    }

    /// A round face with a crown button on top and one hand: the stopwatch.
    private static func stopwatch(_ s: CGFloat, seed: UInt64, amp: Double) -> [Path] {
        let c = CGPoint(x: s * 0.5, y: s * 0.58)
        let r = Double(s) * 0.36
        let face = (0..<18).map { i -> CGPoint in
            let a = Double(i) / 18 * 2 * .pi
            return CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
        }
        var paths = [Doodle.path(Doodle.jitter(face, seed: seed, amp: amp * 0.5), closed: true)]

        var w = Wobble(seed: seed &+ 1)
        let crownTop = c.y - r - 0.12 * s
        var crown = Path()
        crown.move(to: CGPoint(x: c.x, y: c.y - r))
        crown.addLine(to: CGPoint(x: c.x + w.next() * amp, y: crownTop))
        crown.move(to: CGPoint(x: c.x - 0.09 * s, y: crownTop + w.next() * amp))
        crown.addLine(to: CGPoint(x: c.x + 0.09 * s, y: crownTop + w.next() * amp))
        paths.append(crown)

        // A small side button, up and to the right.
        let a = -Double.pi / 4
        var button = Path()
        button.move(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
        button.addLine(to: CGPoint(x: c.x + cos(a) * (r + 0.09 * s) + w.next() * amp,
                                   y: c.y + sin(a) * (r + 0.09 * s)))
        paths.append(button)

        // The hand, from the centre toward one o'clock.
        var hand = Path()
        hand.move(to: c)
        hand.addLine(to: CGPoint(x: c.x + 0.13 * s + w.next() * amp, y: c.y - 0.20 * s + w.next() * amp))
        paths.append(hand)
        return paths
    }
}
