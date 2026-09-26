import InkKit
import SwiftUI
import TetodoroCore

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
    static let size: CGFloat = 10
    static let gap: CGFloat = 3
    static let pitch = size + gap
    static let monthRow: CGFloat = 16
    static let margin: CGFloat = 3
    static let ink: [Double] = [0, 0.16, 0.36, 0.62, 0.92]
}

private struct HeatGrid: View {
    let heatmap: Heatmap
    @Binding var hovered: HeatmapDay?

    var body: some View {
        let columns = heatmap.weeks.count
        Canvas { ctx, _ in
            // Inset so the today/hover outline has room at the grid's edges.
            ctx.translateBy(x: Cell.margin, y: 0)
            drawMonths(ctx)
            for (w, week) in heatmap.weeks.enumerated() {
                for (d, day) in week.enumerated() {
                    guard let day else { continue }
                    draw(day, in: rect(w, d), seed: UInt64(w * 7 + d), ctx: ctx)
                }
            }
        }
        .frame(width: CGFloat(columns) * Cell.pitch - Cell.gap + Cell.margin * 2,
               height: Cell.monthRow + 7 * Cell.pitch - Cell.gap + Cell.margin)
        .padding(.horizontal, -Cell.margin)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hovered = day(at: p)
            case .ended: hovered = nil
            }
        }
    }

    private func rect(_ w: Int, _ d: Int) -> CGRect {
        CGRect(x: CGFloat(w) * Cell.pitch, y: Cell.monthRow + CGFloat(d) * Cell.pitch,
               width: Cell.size, height: Cell.size)
    }

    private func day(at p: CGPoint) -> HeatmapDay? {
        let w = Int((p.x - Cell.margin) / Cell.pitch), d = Int((p.y - Cell.monthRow) / Cell.pitch)
        guard p.y >= Cell.monthRow, heatmap.weeks.indices.contains(w), (0..<7).contains(d) else { return nil }
        return heatmap.weeks[w][d]
    }

    private func draw(_ day: HeatmapDay, in r: CGRect, seed: UInt64, ctx: GraphicsContext) {
        let square = Doodle.polygon(
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)],
            seed: seed &* 31 &+ 7, amp: 0.45)
        if day.level > 0 {
            ctx.fill(square, with: .color(Ink.accent.opacity(Cell.ink[day.level])))
        } else {
            ctx.stroke(square, with: .color(Ink.ghost), lineWidth: 0.8)
        }
        let isToday = Calendar.current.isDateInToday(day.date)
        if isToday || day == hovered {
            ctx.stroke(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 3),
                       with: .color(Ink.ink), lineWidth: isToday ? 1.2 : 1)
        }
    }

    private func drawMonths(_ ctx: GraphicsContext) {
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
                        at: CGPoint(x: CGFloat(w) * Cell.pitch, y: 0), anchor: .topLeading)
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
                    .fill(level == 0 ? Color.clear : Ink.accent.opacity(Cell.ink[level]))
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(level == 0 ? Ink.ghost : .clear))
                    .frame(width: 9, height: 9)
            }
            Text("more")
        }
        .font(Ink.text(11))
    }
}
