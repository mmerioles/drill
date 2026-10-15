import DrillCore
import InkKit
import SwiftUI

extension FocusedValues {
    @Entry var palette: Binding<Bool>?
}

extension EnvironmentValues {
    /// While open, Return belongs to the palette, not the start button.
    @Entry var paletteOpen = false
}

/// ⌘K: a fuzzy finder over everything the window can do.
struct PaletteView: View {
    /// For --render: a typed query, drawn without the AppKit field.
    var preview: String?
    let close: () -> Void
    let openToday: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(Sync.self) private var sync
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool
    /// Most recent first; kept for the life of the process.
    @MainActor private static var recent: [String] = []

    private static let rowHeight: CGFloat = 34

    private struct Command {
        let item: PaletteItem
        let run: () -> Void
    }

    private var commands: [Command] {
        var list: [Command] = []
        func add(_ id: String, _ title: String, _ keywords: [String] = [], hint: String? = nil,
                 _ run: @escaping () -> Void) {
            list.append(Command(item: PaletteItem(id: id, title: title, keywords: keywords, hint: hint), run: run))
        }
        add("toggle", Copy.toggle(running: model.isRunning, active: model.isActive), ["timer"], hint: "space", model.toggle)
        if !model.isStopwatch { add("skip", "skip", ["timer", "next"], hint: "⌘→", model.skip) }
        if model.isActive { add("reset", "reset", ["timer", "stop"], hint: "⌘R", model.reset) }
        if !model.isActive {
            add("mode", "switch to \(Copy.modeName(stopwatch: !model.isStopwatch))", ["timer", "mode"],
                hint: "⌘T", model.switchMode)
        }
        add("settings", "open settings", ["preferences"], hint: "⌘,") { openSettings() }
        add("inspo", "open inspo", ["videos"]) { openWindow(id: "inspo") }
        if sync.isSignedIn {
            add("sync", "sync now", ["upload"], sync.syncNow)
            add("autosync", "turn auto sync \(sync.autoSync ? "off" : "on")", ["sync"]) { sync.autoSync.toggle() }
        }
        add("today", "today", ["sessions", "day"], openToday)
        for tag in model.recentTags {
            add("studying:\(tag)", "studying \(tag)", ["tag"]) { model.tag = tag }
        }
        for tag in model.recentTags {
            add("show:\(tag)", "show \(tag)", ["filter"]) { model.tagFilter = tag }
        }
        add("show-all", "show all", ["filter"]) { model.tagFilter = nil }
        return list
    }

    private var rows: [(result: PaletteResult, run: () -> Void)] {
        let all = commands
        var rows = Palette.rank(all.map(\.item), query: shownQuery, recent: Self.recent).map { r in
            (r, all.first { $0.item.id == r.item.id }!.run)
        }
        let tag = shownQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !tag.isEmpty && !model.recentTags.contains(tag) {
            let item = PaletteItem(id: "new-tag", title: "studying \"\(tag)\"")
            rows.append((PaletteResult(item: item, score: 0, highlights: []), { model.tag = tag }))
        }
        return rows
    }

    private var shownQuery: String { preview ?? query }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            field
                .padding(.horizontal, 16)
                .frame(height: 46)
            Rectangle().fill(Ink.ghost).frame(height: 1)
            if rows.isEmpty {
                Text("no matches")
                    .font(Ink.text(14))
                    .foregroundStyle(Ink.faint)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                list(rows)
            }
        }
        // A shade off the paper, so it lifts in dark too, where shadows vanish.
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.ink.opacity(0.035)).background(Ink.paper, in: .rect(cornerRadius: 10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.ghost, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, y: 10)
        .onAppear { focused = true }
    }

    @ViewBuilder private var field: some View {
        if let preview {
            Text(preview).font(Ink.text(16)).foregroundStyle(Ink.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("", text: $query)
                .textFieldStyle(.plain)
                .font(Ink.text(16))
                .foregroundStyle(Ink.ink)
                .tint(Ink.ink)
                .focused($focused)
                .background(alignment: .leading) {
                    if query.isEmpty {
                        Text("type a command…").font(Ink.text(16)).foregroundStyle(Ink.ink.opacity(0.28))
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: query) { selected = 0 }
                .onSubmit { run(rows) }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(phases: .down) { press in
                    guard press.modifiers == .control else { return .ignored }
                    switch press.key.character {
                    case "n", "\u{0E}": return move(1)
                    case "p", "\u{10}": return move(-1)
                    default: return .ignored
                    }
                }
        }
    }

    @ViewBuilder private func list(_ rows: [(result: PaletteResult, run: () -> Void)]) -> some View {
        let stack = VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                row(rows[i].result, selected: i == selected)
                    .id(i)
                    .onHover { if $0 { selected = i } }
                    .onTapGesture { selected = i; run(rows) }
            }
        }
        .padding(6)
        if rows.count <= 8 {
            stack
        } else {
            ScrollViewReader { proxy in
                ScrollView { stack }
                    .scrollIndicators(.never)
                    .frame(height: 8 * Self.rowHeight + 12)
                    .onChange(of: selected) { proxy.scrollTo(selected) }
            }
        }
    }

    private func row(_ r: PaletteResult, selected: Bool) -> some View {
        HStack {
            title(r).font(Ink.text(14))
            Spacer(minLength: 16)
            if let hint = r.item.hint {
                Text(hint).font(Ink.text(12)).foregroundStyle(Ink.faint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Ink.ink.opacity(0.07) : .clear))
        .contentShape(Rectangle())
    }

    /// Matched letters in full ink, the rest faint. Nothing to show: all ink.
    private func title(_ r: PaletteResult) -> Text {
        let marks = Set(r.highlights)
        var out = AttributedString()
        for (i, c) in r.item.title.enumerated() {
            var piece = AttributedString(String(c))
            piece.foregroundColor = marks.isEmpty || marks.contains(i) ? Ink.ink : Ink.faint
            out += piece
        }
        return Text(out)
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let count = rows.count
        guard count > 0 else { return .handled }
        selected = (selected + by + count) % count
        return .handled
    }

    private func run(_ rows: [(result: PaletteResult, run: () -> Void)]) {
        guard rows.indices.contains(selected) else { return }
        let (result, action) = rows[selected]
        if result.item.id != "new-tag" {
            Self.recent.removeAll { $0 == result.item.id }
            Self.recent.insert(result.item.id, at: 0)
        }
        close()
        action()
    }
}
