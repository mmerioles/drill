import SwiftUI

/// Small hand-drawn marks. The Teto nods live here: her drill twintail for
/// focus, a baguette for breaks — never a face, never a colour.
public struct Glyph: View {
    public enum Kind: Hashable, Sendable { case drill, baguette, check }

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
                }
            }
        }
        .frame(width: size, height: size)
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
}
