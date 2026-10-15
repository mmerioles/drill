import InkKit
import SwiftUI
import DrillCore

/// A day's popover from the heatmap: its blocks, which can be edited,
/// removed (with undo) or added.
struct DayDetail: View {
    let day: Date
    /// For --render, which can't click.
    var preview: Preview = .none
    enum Preview { case none, editingFirst, adding, removedFirst }

    @Environment(AppModel.self) private var model
    /// Passed in, so the popover lays out once at its real size.
    @State private var sessions: [FocusSession]
    @State private var editing: Editing?
    /// Undoable removals, by id, to their tombstones.
    @State private var removed: [UUID: FocusSession] = [:]

    init(day: Date, sessions: [FocusSession], preview: Preview = .none) {
        self.day = day
        self.preview = preview
        _sessions = State(initialValue: sessions)
        switch preview {
        case .none: break
        case .editingFirst: _editing = State(initialValue: sessions.first.map { .session($0.id) })
        case .adding: _editing = State(initialValue: .adding)
        case .removedFirst: if let first = sessions.first { _removed = State(initialValue: [first.id: first]) }
        }
    }

    private enum Editing: Equatable {
        case session(UUID)
        case adding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.formatted(Copy.dayFormat).lowercased())
                    .font(Ink.text(20, .semibold))
                    .foregroundStyle(Ink.ink)
                Spacer(minLength: 16)
                if total > 0 {
                    Text(Copy.amount(total))
                        .font(Ink.text(15, .semibold))
                        .foregroundStyle(Ink.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            if sessions.isEmpty && editing != .adding {
                Text("nothing logged.")
                    .font(Ink.text(15))
                    .foregroundStyle(Ink.faint)
            } else if sessions.count <= 8 {
                list
            } else {
                // A busy day scrolls rather than growing past the screen.
                ScrollView { list }
                    .scrollIndicators(.never)
                    .frame(height: 7 * 44)
            }

            if editing != .adding {
                Button {
                    editing = .adding
                } label: {
                    Label("add a block", systemImage: "plus")
                        .labelStyle(AddLabel())
                }
                .buttonStyle(.inkLink(selected: false, size: 15))
                .frame(minHeight: 24)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Ink.paper)
        .animation(Ink.snap, value: editing)
        .animation(Ink.snap, value: removed.keys.sorted { $0.uuidString < $1.uuidString })
        .animation(Ink.snap, value: sessions.map(\.id))

        .accessibilityElement(children: .contain)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions) { session in
                Group {
                    if removed[session.id] != nil {
                        RemovedRow { undo(session) }
                    } else if editing == .session(session.id) {
                        BlockEditor(day: day, start: session.startedAt, length: session.focusSeconds,
                                    tag: session.tag ?? "",
                                    save: { start, length, tag in
                                        model.update(session, start: start, length: length, tag: tag)
                                        editing = nil
                                        refresh()
                                    },
                                    cancel: { editing = nil })
                    } else {
                        SessionRow(session: session,
                                   open: { editing = .session(session.id) },
                                   remove: { remove(session) })
                    }
                }
                .transition(.opacity)
            }
            if editing == .adding {
                BlockEditor(day: day, start: defaultStart, length: 25 * 60, tag: model.suggestedTag,
                            save: { start, length, tag in
                                model.add(start: start, length: length, tag: tag)
                                editing = nil
                                refresh()
                            },
                            cancel: { editing = nil })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Rows sit flush with the title; their hover wash reaches past it.
        .padding(.horizontal, -8)
    }

    private var total: TimeInterval {
        sessions.filter { removed[$0.id] == nil }.reduce(0) { $0 + $1.focusSeconds }
    }

    /// A new block starts after the day's last one, or at 9am, and always
    /// ends by now.
    private var defaultStart: Date {
        let calendar = Calendar.current
        var start = sessions.last.map(\.endedAt)
            ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        let latest = Date() - 25 * 60
        if start > latest { start = max(calendar.startOfDay(for: day), latest) }
        return start
    }

    private func refresh() {
        // Removed rows stay put (as "removed · undo") until the popover closes.
        let live = model.sessions(on: day)
        let liveIDs = Set(live.map(\.id))
        let kept = sessions.filter { removed[$0.id] != nil && !liveIDs.contains($0.id) }
        sessions = (live + kept).sorted { $0.startedAt < $1.startedAt }
    }

    private func remove(_ session: FocusSession) {
        removed[session.id] = model.delete(session)
        Task {
            try? await Task.sleep(for: .seconds(6))
            guard removed.removeValue(forKey: session.id) != nil else { return }
            sessions.removeAll { $0.id == session.id }
        }
        if editing == .session(session.id) { editing = nil }
    }

    private func undo(_ session: FocusSession) {
        if let tombstone = removed.removeValue(forKey: session.id) { model.restore(tombstone) }
        refresh()
    }
}

/// On hover, the length makes way for ×; a click opens the editor.
private struct SessionRow: View {
    let session: FocusSession
    let open: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Stopwatch and added blocks have no plan; pomodoro blocks do.
            Glyph(session.tag == Copy.intervalsTag ? .runner : session.plannedSeconds == 0 ? .stopwatch : .tomato,
                  size: 15, boiling: false,
                  lineWidth: 1.3, tint: Ink.faint)
            Text(session.startedAt.formatted(Copy.timeFormat).lowercased())
                .foregroundStyle(Ink.faint)
                .monospacedDigit()
                .frame(width: 72, alignment: .leading)
            Text(session.tag ?? "untagged")
                .foregroundStyle(session.tag == nil ? Ink.faint : Ink.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            ZStack(alignment: .trailing) {
                Text(Copy.amount(session.focusSeconds))
                    .foregroundStyle(Ink.ink)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .opacity(hovered ? 0 : 1)
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.inkLink(selected: false, size: 15))
                .opacity(hovered ? 1 : 0)
                .help("remove")
                .accessibilityLabel("remove")
            }
        }
        .font(Ink.text(15))
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Ink.ink.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovered = $0 }
        .pointerStyle(.link)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.tag ?? "untagged"), \(Copy.amount(session.focusSeconds)), at \(session.startedAt.formatted(Copy.timeFormat))")
        .accessibilityAction(named: "edit", open)
        .accessibilityAction(named: "remove", remove)
    }
}

private struct RemovedRow: View {
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("removed")
                .foregroundStyle(Ink.faint)
            Text("·").foregroundStyle(Ink.faint)
            Button("undo", action: undo)
                .buttonStyle(.inkLink(selected: true, size: 15))
            Spacer()
        }
        .font(Ink.text(15))
        .padding(.horizontal, 8)
        .frame(height: 44)
    }
}

/// Ends can't run past now; lengths stay between a minute and 12 hours.
private struct BlockEditor: View {
    let day: Date
    @State var start: Date
    @State var length: TimeInterval
    @State var tag: String
    let save: (Date, TimeInterval, String?) -> Void
    let cancel: () -> Void
    @FocusState private var tagFocused: Bool

    init(day: Date, start: Date, length: TimeInterval, tag: String,
         save: @escaping (Date, TimeInterval, String?) -> Void, cancel: @escaping () -> Void) {
        self.day = day
        _start = State(initialValue: start)
        // Whole minutes, so an edited block doesn't look off by seconds.
        _length = State(initialValue: max(60, (length / 60).rounded() * 60))
        _tag = State(initialValue: tag)
        self.save = save
        self.cancel = cancel
    }

    private static let longest: TimeInterval = 12 * 3600

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DatePicker("", selection: startOfDayBound, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
                VStack(spacing: 3) {
                    TextField("", text: $tag)
                        .textFieldStyle(.plain)
                        .font(Ink.text(15, .medium))
                        .foregroundStyle(Ink.ink)
                        .focused($tagFocused)
                        .onSubmit(commit)
                        .background(alignment: .leading) {
                            if tag.isEmpty {
                                Text("anything").font(Ink.text(15)).foregroundStyle(Ink.ink.opacity(0.28))
                                    .allowsHitTesting(false)
                            }
                        }
                    Rectangle().fill(tagFocused ? Ink.faint : Ink.ghost).frame(height: 1)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    step("minus", by: -5 * 60).disabled(length <= 60)
                    Text(Copy.amount(length))
                        .font(Ink.text(15, .medium))
                        .foregroundStyle(Ink.ink)
                        .monospacedDigit()
                        .frame(minWidth: 52)
                        .contentTransition(.numericText())
                    step("plus", by: 5 * 60).disabled(length >= Self.longest)
                }
                Spacer(minLength: 8)
                Button("cancel", action: cancel)
                    .buttonStyle(.inkLink(selected: false, size: 15))
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                Button("save", action: commit)
                    .buttonStyle(InkCapsuleStyle(size: 14, height: 40))
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
                    .disabled(!valid)
                    .opacity(valid ? 1 : 0.35)
            }

            if let problem {
                Text(problem)
                    .font(Ink.text(13))
                    .foregroundStyle(Ink.faint)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.ink.opacity(0.045)))
        .animation(Ink.snap, value: length)
        .onAppear { tagFocused = tag.isEmpty }
    }

    /// The picker shows a time; this keeps the block on its own day.
    private var startOfDayBound: Binding<Date> {
        Binding(get: { start }, set: { picked in
            let calendar = Calendar.current
            let time = calendar.dateComponents([.hour, .minute], from: picked)
            start = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? picked
        })
    }

    private var problem: String? {
        start + length > Date() ? "a block can't end in the future." : nil
    }

    private var valid: Bool { problem == nil && length >= 60 && length <= Self.longest }

    private func step(_ symbol: String, by delta: TimeInterval) -> some View {
        Button {
            // From an odd length, the first step lands on a multiple of five.
            let five: TimeInterval = 5 * 60
            let next = delta > 0 ? ((length / five).rounded(.down) + 1) * five
                                 : ((length / five).rounded(.up) - 1) * five
            length = min(Self.longest, max(60, next))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.inkLink(selected: false, size: 15))
        .accessibilityLabel(delta > 0 ? "longer" : "shorter")
    }

    private func commit() {
        guard valid else { return }
        save(start, length, tag)
    }
}

/// A small plus on the text's baseline.
private struct AddLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}
