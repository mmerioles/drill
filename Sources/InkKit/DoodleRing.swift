import SwiftUI

/// The timer's face: a dotted pencil track with an inked arc drawn over it
/// clockwise from twelve o'clock, and a pen-tip dot where the ink stops.
public struct DoodleRing: View {
    var progress: Double
    var lineWidth: CGFloat
    var boiling: Bool

    public init(progress: Double, lineWidth: CGFloat = 2.6, boiling: Bool = true) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.boiling = boiling
    }

    public var body: some View {
        Boil(active: boiling) { tick in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - lineWidth * 2
                let samples = 72

                func point(_ i: Int, of n: Int, sweep: Double) -> CGPoint {
                    let a = -Double.pi / 2 + sweep * Double(i) / Double(n)
                    return CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                }

                let track = (0..<samples).map { point($0, of: samples, sweep: 2 * .pi) }
                ctx.stroke(
                    Doodle.path(Doodle.jitter(track, seed: tick &+ 3, amp: 0.7), closed: true),
                    with: .color(Ink.ghost),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [1.5, 6]))

                let p = min(1, max(0, progress))
                guard p > 0.001 else { return }
                let n = max(2, Int(Double(samples) * p))
                let arc = Doodle.jitter(
                    (0...n).map { point($0, of: n, sweep: 2 * .pi * p) }, seed: tick &+ 17, amp: 0.9)
                ctx.stroke(
                    Doodle.path(arc, closed: false), with: .color(Ink.accent),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

                if let tip = arc.last {
                    let d = lineWidth * 2.4
                    ctx.fill(Path(ellipseIn: CGRect(x: tip.x - d / 2, y: tip.y - d / 2, width: d, height: d)),
                             with: .color(Ink.accent))
                }
            }
        }
    }
}
