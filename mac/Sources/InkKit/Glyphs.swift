import SwiftUI

/// Small hand-drawn marks. The Teto nods live here: her drill twintail for
/// focus, a baguette for breaks — never a face, never a colour. A tomato and
/// a stopwatch name the timer's two modes.
public struct Glyph: View {
    public enum Kind: Hashable, Sendable { case drill, baguette, check, tomato, stopwatch }

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
                case .baguette:
                    for path in Self.baguette(s, seed: tick &+ 9, amp: amp) {
                        ctx.stroke(path, with: .color(tint), style: style)
                    }
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
    static func drill(_ s: CGFloat, seed: UInt64, amp: Double) -> Path {
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

    /// A loaf tilted on the diagonal with three scores across its back.
    static func baguette(_ s: CGFloat, seed: UInt64, amp: Double) -> [Path] {
        let c = CGPoint(x: s / 2, y: s / 2)
        let angle = -Double.pi / 4
        func rotate(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: c.x + x * cos(angle) - y * sin(angle), y: c.y + x * sin(angle) + y * cos(angle))
        }
        let half = Double(s) * 0.44, thick = Double(s) * 0.13
        // Stadium outline: two straight sides and rounded ends.
        var outline: [CGPoint] = []
        for i in 0..<12 {
            let a = -Double.pi / 2 + Double(i) / 11 * .pi
            outline.append(rotate(half - thick + cos(a) * thick, sin(a) * thick))
        }
        for i in 0..<12 {
            let a = Double.pi / 2 + Double(i) / 11 * .pi
            outline.append(rotate(-half + thick + cos(a) * thick, sin(a) * thick))
        }
        var paths = [Doodle.path(Doodle.jitter(outline, seed: seed, amp: amp * 0.5), closed: true)]
        var w = Wobble(seed: seed &+ 1)
        for x in [-0.45, 0.0, 0.45] {
            let dx = x * half
            var p = Path()
            p.move(to: rotate(dx - thick * 0.35 + w.next() * amp, -thick * 0.45))
            p.addLine(to: rotate(dx + thick * 0.35 + w.next() * amp, thick * 0.45))
            paths.append(p)
        }
        return paths
    }

    /// A round fruit, a little wider than tall, with a star of five leaves
    /// lying over its shoulders and a short stem: the pomodoro.
    static func tomato(_ s: CGFloat, seed: UInt64, amp: Double) -> [Path] {
        let c = CGPoint(x: s * 0.5, y: s * 0.58)
        let rx = Double(s) * 0.42, ry = Double(s) * 0.33
        // A soft dip at the top where the stem sits.
        let body = (0..<22).map { i -> CGPoint in
            let a = Double(i) / 22 * 2 * .pi - .pi / 2
            let dip = 1 - 0.12 * pow(max(0, -sin(a)), 10)
            return CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * ry * dip)
        }
        var paths = [Doodle.path(Doodle.jitter(body, seed: seed, amp: amp * 0.5), closed: true)]

        // Five leaves fanning out from the stem's foot, each bowed and
        // drooping onto the fruit like a calyx seen from the side.
        let top = CGPoint(x: c.x, y: c.y - ry * 0.86)
        var w = Wobble(seed: seed &+ 1)
        for (dx, dy) in [(-0.27, 0.10), (-0.15, 0.15), (0.0, 0.11), (0.15, 0.15), (0.27, 0.10)] {
            let tip = CGPoint(x: top.x + dx * s + w.next() * amp, y: top.y + dy * s + w.next() * amp)
            var p = Path()
            p.move(to: top)
            p.addQuadCurve(to: tip, control: CGPoint(x: top.x + dx * s * 0.6, y: top.y - 0.02 * s))
            paths.append(p)
        }
        var stem = Path()
        stem.move(to: top)
        stem.addQuadCurve(to: CGPoint(x: top.x + 0.07 * s, y: top.y - 0.17 * s + w.next() * amp),
                          control: CGPoint(x: top.x - 0.01 * s, y: top.y - 0.12 * s))
        paths.append(stem)
        return paths
    }

    /// A round face with a crown button on top and one hand: the stopwatch.
    static func stopwatch(_ s: CGFloat, seed: UInt64, amp: Double) -> [Path] {
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
