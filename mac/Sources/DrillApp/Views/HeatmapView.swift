import InkKit
import SwiftUI
import DrillCore

/// A year, a week per column. Each cell wobbles by a fixed seed, so the grid
/// looks hand-ruled but holds still.
struct HeatmapSection: View {
    /// Bumped to open today's popover, e.g. from the palette.
    var openToday = 0
    @Environment(AppModel.self) private var model
    @State private var hovered: HeatmapDay?
    @State private var opened: OpenDay?
    /// The column's width; the grid takes what it needs of it.
    @State private var width: CGFloat = 700

    var body: some View {
        let m = GridMetrics(width: width, weeks: model.heatmap.weeks.count)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                TagFilter()
            }

            HeatGrid(heatmap: model.heatmap, metrics: m, hovered: $hovered, opened: $opened, openToday: openToday)
                .padding(.top, 12)
                // The grid is a picture; VoiceOver gets its summary.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("your year")
                .accessibilityValue(summary)

            caption(legend: m.width >= 600)
                .font(Ink.text(15))
                .foregroundStyle(Ink.faint)
                .frame(height: 24)
                .padding(.top, 16)
                .animation(nil, value: hovered)
        }
        // Filter and stats align to the grid's own edges when the year fits
        // at the largest cell and leaves the column's sides empty.
        .frame(width: m.width)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }

    @ViewBuilder private func caption(legend: Bool) -> some View {
        if let day = hovered {
            HStack(spacing: 6) {
                Text(day.date.formatted(Copy.dayFormat).lowercased())
                    .foregroundStyle(Ink.ink)
                Text("—")
                Text(day.seconds > 0 ? Copy.amount(day.seconds) : "nothing logged.")
            }
        } else {
            let h = model.heatmap
            HStack(spacing: 24) {
                today
                stat("this week", Copy.amount(h.thisWeek))
                stat("streak", Copy.streak(h.streak))
                Spacer()
                if legend { Legend() }
            }
        }
    }

    /// "today 1h 15m / 2h ◔". The goal shows only unfiltered, since it counts every tag.
    private var today: some View {
        HStack(spacing: 5) {
            Text("today")
            Text(Copy.amount(model.heatmap.today)).foregroundStyle(Ink.ink).fontWeight(.semibold)
            if model.dailyGoal > 0 && model.tagFilter == nil {
                Text("/ \(Copy.amount(model.dailyGoal))")
                GoalRing(progress: model.todayTotal / model.dailyGoal)
                    .padding(.leading, 2)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.dailyGoal > 0 && model.tagFilter == nil
            ? "today \(Copy.amount(model.todayTotal)) of \(Copy.amount(model.dailyGoal))"
            : "today \(Copy.amount(model.heatmap.today))")
    }

    private var summary: String {
        let h = model.heatmap
        return "today \(Copy.amount(h.today)), this week \(Copy.amount(h.thisWeek)), streak \(Copy.streak(h.streak))"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
            Text(value).foregroundStyle(Ink.ink).fontWeight(.semibold)
        }
    }
}

/// `anchor` places the popover's arrow.
struct OpenDay: Identifiable, Equatable {
    let day: Date
    let anchor: CGRect
    var id: Date { day }
}

private struct TagFilter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 16) {
            Button("all") { model.tagFilter = nil }
                .buttonStyle(.inkLink(selected: model.tagFilter == nil, size: 15))
            ForEach(model.recentTags, id: \.self) { tag in
                Button(tag) { model.tagFilter = tag }
                    .buttonStyle(.inkLink(selected: model.tagFilter == tag, size: 15))
            }
        }
    }
}

private enum Cell {
    static let gap: CGFloat = 2
    static let min: CGFloat = 11
    static let max: CGFloat = 14
    /// Month labels: a 12-size line, 6 above the cells.
    static let monthRow: CGFloat = 20
    static let margin: CGFloat = 3
    static let ink: [Double] = [0, 0.16, 0.36, 0.62, 0.92]
    /// Empty days: a faint wash, quieter than an outline at 365 cells.
    static let empty = Ink.ink.opacity(0.055)
}

/// Square cells with a 2 gap, 11 to 14 across. A narrow column shows the
/// trailing weeks that fit; a wide one caps the cell and leaves the sides.
private struct GridMetrics {
    let size: CGFloat
    /// Weeks shown, from the end of the year.
    let columns: Int
    var pitch: CGFloat { size + Cell.gap }
    var width: CGFloat { CGFloat(columns) * pitch - Cell.gap }
    var height: CGFloat { Cell.monthRow + 7 * pitch - Cell.gap }

    init(width: CGFloat, weeks: Int) {
        let fit = Int((width + Cell.gap) / (Cell.min + Cell.gap))
        let n = max(1, min(weeks, fit))
        columns = n
        size = min(Cell.max, (width - CGFloat(n - 1) * Cell.gap) / CGFloat(n))
    }
}

private struct HeatGrid: View {
    let heatmap: Heatmap
    let metrics: GridMetrics
    @Binding var hovered: HeatmapDay?
    @Binding var opened: OpenDay?
    let openToday: Int
    @Environment(AppModel.self) private var model

    private var weeks: [[HeatmapDay?]] { Array(heatmap.weeks.suffix(metrics.columns)) }

    var body: some View {
        let m = metrics
        let weeks = weeks
        Canvas { ctx, _ in
            // Inset so the today/hover outline has room at the grid's edges.
            ctx.translateBy(x: Cell.margin, y: 0)
            drawMonths(ctx, m, weeks)
            for (w, week) in weeks.enumerated() {
                for (d, day) in week.enumerated() {
                    guard let day else { continue }
                    draw(day, in: rect(w, d, m), seed: UInt64(w * 7 + d), ctx: ctx)
                }
            }
        }
        .frame(width: m.width + Cell.margin * 2, height: m.height)
        // Pointer, clicks and the popover's arrow all in the canvas's own
        // space, before the negative padding below shifts it.
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hovered = day(at: p, m, weeks)
            case .ended: hovered = nil
            }
        }
        .onTapGesture { p in
            guard let (w, d) = cell(at: p, m, weeks), let day = weeks[w][d] else { return }
            if opened?.day == day.date { opened = nil; return }
            opened = OpenDay(day: day.date, anchor: rect(w, d, m).offsetBy(dx: Cell.margin, dy: 0))
        }
        .pointerStyle(hovered == nil ? nil : .link)
        .onChange(of: openToday) {
            for (w, week) in weeks.enumerated() {
                for (d, day) in week.enumerated() {
                    if let day, Calendar.current.isDateInToday(day.date) {
                        opened = OpenDay(day: day.date, anchor: rect(w, d, m).offsetBy(dx: Cell.margin, dy: 0))
                    }
                }
            }
        }
        .popover(item: $opened, attachmentAnchor: .rect(.rect(opened?.anchor ?? .zero)), arrowEdge: .top) { open in
            DayDetail(day: open.day, sessions: model.sessions(on: open.day))
                .environment(model)
                .presentationBackground(Ink.paper)
        }
        .padding(.horizontal, -Cell.margin)
    }

    private func rect(_ w: Int, _ d: Int, _ m: GridMetrics) -> CGRect {
        CGRect(x: CGFloat(w) * m.pitch, y: Cell.monthRow + CGFloat(d) * m.pitch,
               width: m.size, height: m.size)
    }

    private func cell(at p: CGPoint, _ m: GridMetrics, _ weeks: [[HeatmapDay?]]) -> (Int, Int)? {
        let x = p.x - Cell.margin, y = p.y - Cell.monthRow
        guard x >= 0, y >= 0 else { return nil }
        let w = Int(x / m.pitch), d = Int(y / m.pitch)
        guard weeks.indices.contains(w), (0..<7).contains(d) else { return nil }
        return (w, d)
    }

    private func day(at p: CGPoint, _ m: GridMetrics, _ weeks: [[HeatmapDay?]]) -> HeatmapDay? {
        cell(at: p, m, weeks).flatMap { weeks[$0.0][$0.1] }
    }

    private func draw(_ day: HeatmapDay, in r: CGRect, seed: UInt64, ctx: GraphicsContext) {
        let square = Doodle.polygon(
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)],
            seed: seed &* 31 &+ 7, amp: 0.35)
        ctx.fill(square, with: .color(day.level > 0 ? Ink.accent.opacity(Cell.ink[day.level]) : Cell.empty))
        let isToday = Calendar.current.isDateInToday(day.date)
        let isOpen = opened?.day == day.date
        if isToday || isOpen || day == hovered {
            ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.75, dy: -1.75), cornerRadius: 3),
                       with: .color(isToday || isOpen ? Ink.ink : Ink.faint), lineWidth: isOpen ? 1.5 : 1.1)
        }
    }

    private func drawMonths(_ ctx: GraphicsContext, _ m: GridMetrics, _ weeks: [[HeatmapDay?]]) {
        let calendar = Calendar.current
        var lastMonth = -1
        for (w, week) in weeks.enumerated() {
            guard let first = week.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: first.date)
            // Label a month at its first full column, and not the half-column
            // at the grid's left edge.
            if month != lastMonth {
                if lastMonth != -1 || calendar.component(.day, from: first.date) <= 7 {
                    ctx.draw(
                        Text(first.date.formatted(.dateTime.month(.abbreviated)).lowercased())
                            .font(Ink.text(12)).foregroundStyle(Ink.faint),
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
                    .frame(width: 10, height: 10)
            }
            Text("more")
        }
        .font(Ink.text(12))
        .accessibilityHidden(true)
    }
}

/// Today against the daily goal: a ring that fills, then a check.
struct GoalRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            if progress >= 1 {
                Glyph(.check, size: 14, boiling: false, lineWidth: 1.6, tint: Ink.accent)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                Circle().stroke(Ink.ghost, lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Ink.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .transition(.opacity)
            }
        }
        .frame(width: 11, height: 11)
        .animation(.spring(response: 0.42, dampingFraction: 0.6), value: progress >= 1)
        .animation(Ink.ease, value: progress)
    }
}
