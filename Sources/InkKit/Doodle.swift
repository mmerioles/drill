import SwiftUI

// MARK: Doodle machinery
// Every stroke is jittered by a seeded wobble, and the seed steps every
// 0.4s — the classic hand-drawn "boil". Amplitude stays around a point so it
// reads as pen texture in motion, not noise.

public struct Wobble {
    public var seed: UInt64
    public init(seed: UInt64) { self.seed = seed }

    /// Next value in -0.5..<0.5.
    public mutating func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) % 1000) / 1000 - 0.5
    }
}

public enum Doodle {
    public static func jitter(_ pts: [CGPoint], seed: UInt64, amp: Double = 1.2) -> [CGPoint] {
        var w = Wobble(seed: seed)
        return pts.map { CGPoint(x: $0.x + w.next() * amp * 2, y: $0.y + w.next() * amp * 2) }
    }

    /// A soft curve through `pts`. Closed paths run midpoint to midpoint all
    /// the way around, so the seam lands mid-curve and never shows a corner.
    public static func path(_ pts: [CGPoint], closed: Bool) -> Path {
        var p = Path()
        guard pts.count > 1 else { return p }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        if closed {
            let n = pts.count
            p.move(to: mid(pts[n - 1], pts[0]))
            for i in 0..<n {
                p.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i])
            }
            p.closeSubpath()
        } else {
            p.move(to: pts[0])
            for i in 1..<pts.count {
                p.addQuadCurve(to: mid(pts[i - 1], pts[i]), control: pts[i - 1])
            }
            p.addLine(to: pts[pts.count - 1])
        }
        return p
    }

    /// A polygon whose edges wobble but whose corners stay corners.
    public static func polygon(_ corners: [CGPoint], seed: UInt64, amp: Double = 1.0) -> Path {
        var samples: [CGPoint] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            for t in 0..<3 {
                let f = Double(t) / 3
                samples.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        let pts = jitter(samples, seed: seed, amp: amp)
        var p = Path()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }
}

/// Re-renders its content with a new seed every `step` seconds. Holds still
/// when `active` is false or the user has Reduce Motion on.
public struct Boil<Content: View>: View {
    var step: Double
    var active: Bool
    @ViewBuilder var content: (UInt64) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(step: Double = 0.4, active: Bool = true, @ViewBuilder content: @escaping (UInt64) -> Content) {
        self.step = step
        self.active = active
        self.content = content
    }

    public var body: some View {
        if active && !reduceMotion {
            TimelineView(.periodic(from: .now, by: step)) { ctx in
                content(UInt64(ctx.date.timeIntervalSinceReferenceDate / step))
            }
        } else {
            content(0)
        }
    }
}
