import InkKit
import SwiftUI
import DrillCore

/// A year of study, a week per column. Cells are inked squares whose density
/// is the day's focus time; each wobbles by its own fixed seed, so the grid
/// looks hand-ruled but holds perfectly still.
struct HeatmapSection: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: HeatmapDay?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("your year")
                    .font(Ink.word(18))
                    .foregroundStyle(Ink.ink)
                Spacer()
                TagFilter()
            }

            HeatGrid(heatmap: model.heatmap, hovered: $hovered)

            caption
                .font(Ink.text(13))
                .foregroundStyle(Ink.faint)
                .frame(height: 16)
                .animation(nil, value: hovered)
        }
    }

    @ViewBuilder private var caption: some View {
        if let day = hovered {
            HStack(spacing: 6) {
                Text(day.date.formatted(Copy.dayFormat).lowercased())
                    .foregroundStyle(Ink.ink)
                Text("—")
                Text(day.seconds > 0 ? Copy.amount(day.seconds) : "nothing logged.")
            }
        } else {
            let h = model.heatmap
            HStack(spacing: 22) {
                stat("today", Copy.amount(h.today))
                stat("this week", Copy.amount(h.thisWeek))
                stat("streak", Copy.streak(h.streak))
                Spacer()
                Legend()
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
            Text(value).foregroundStyle(Ink.ink).fontWeight(.medium)
        }
    }
}

private struct TagFilter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            Button("all") { model.tagFilter = nil }
                .buttonStyle(.inkLink(selected: model.tagFilter == nil, size: 13))
            ForEach(model.recentTags, id: \.self) { tag in
                Button(tag) { model.tagFilter = tag }
                    .buttonStyle(.inkLink(selected: model.tagFilter == tag, size: 13))
            }
        }
    }
}

private enum Cell {
    /// Gap as a fraction of the pitch; the cell size follows from the width.
    static let gapRatio: CGFloat = 0.24
    static let monthRow: CGFloat = 16
    static let margin: CGFloat = 3
    static let ink: [Double] = [0, 0.16, 0.36, 0.62, 0.92]
    /// Empty days: a faint wash, quieter than an outline at 365 cells.
    static let empty = Ink.ink.opacity(0.055)
}

/// Cell geometry for a grid of `columns` weeks stretched across `width`.
private struct GridMetrics {
    let pitch: CGFloat
    var size: CGFloat { pitch * (1 - Cell.gapRatio) }
    var height: CGFloat { Cell.monthRow + 7 * pitch - (pitch - size) + Cell.margin }

    init(width: CGFloat, columns: Int) {
        let usable = width - Cell.margin * 2
        let n = CGFloat(max(columns, 1))
        pitch = usable / (n - Cell.gapRatio)
    }
}

private struct HeatGrid: View {
    let heatmap: Heatmap
    @Binding var hovered: HeatmapDay?
    @State private var width: CGFloat = 706

    var body: some View {
        let m = GridMetrics(width: width, columns: heatmap.weeks.count)
        Canvas { ctx, _ in
            // Inset so the today/hover outline has room at the grid's edges.
            ctx.translateBy(x: Cell.margin, y: 0)
            drawMonths(ctx, m)
            for (w, week) in heatmap.weeks.enumerated() {
                for (d, day) in week.enumerated() {
                    guard let day else { continue }
                    draw(day, in: rect(w, d, m), seed: UInt64(w * 7 + d), ctx: ctx)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: m.height)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .padding(.horizontal, -Cell.margin)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hovered = day(at: p, m)
            case .ended: hovered = nil
            }
        }
    }

    private func rect(_ w: Int, _ d: Int, _ m: GridMetrics) -> CGRect {
        CGRect(x: CGFloat(w) * m.pitch, y: Cell.monthRow + CGFloat(d) * m.pitch,
               width: m.size, height: m.size)
    }

    private func day(at p: CGPoint, _ m: GridMetrics) -> HeatmapDay? {
        let w = Int((p.x - Cell.margin) / m.pitch), d = Int((p.y - Cell.monthRow) / m.pitch)
        guard p.y >= Cell.monthRow, heatmap.weeks.indices.contains(w), (0..<7).contains(d) else { return nil }
        return heatmap.weeks[w][d]
    }

    private func draw(_ day: HeatmapDay, in r: CGRect, seed: UInt64, ctx: GraphicsContext) {
        let square = Doodle.polygon(
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)],
            seed: seed &* 31 &+ 7, amp: 0.35)
        ctx.fill(square, with: .color(day.level > 0 ? Ink.accent.opacity(Cell.ink[day.level]) : Cell.empty))
        let isToday = Calendar.current.isDateInToday(day.date)
        if isToday || day == hovered {
            ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.75, dy: -1.75), cornerRadius: 3),
                       with: .color(isToday ? Ink.ink : Ink.faint), lineWidth: 1.1)
        }
    }

    private func drawMonths(_ ctx: GraphicsContext, _ m: GridMetrics) {
        let calendar = Calendar.current
        var lastMonth = -1
        for (w, week) in heatmap.weeks.enumerated() {
            guard let first = week.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: first.date)
            // Label a month at its first full column, and not the half-column
            // at the grid's left edge.
            if month != lastMonth {
                if lastMonth != -1 || calendar.component(.day, from: first.date) <= 7 {
                    ctx.draw(
                        Text(first.date.formatted(.dateTime.month(.abbreviated)).lowercased())
                            .font(Ink.text(10)).foregroundStyle(Ink.faint),
                        at: CGPoint(x: CGFloat(w) * m.pitch, y: 0), anchor: .topLeading)
                }
                lastMonth = month
            }
        }
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("less")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level == 0 ? Cell.empty : Ink.accent.opacity(Cell.ink[level]))
                    .frame(width: 9, height: 9)
            }
            Text("more")
        }
        .font(Ink.text(11))
    }
}
