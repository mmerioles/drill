import InkKit
import SwiftUI
import DrillCore

/// The ring, digits, tag field and controls. Between blocks, clicking the
/// face switches pomodoro ⇄ stopwatch.
struct TimerView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var tagFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ZStack {
                DoodleRing(progress: model.progress, boiling: model.isRunning)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    // A single quiet word, only when there's something to say;
                    // the fixed height keeps the digits from jumping.
                    Text(model.status ?? " ")
                        .font(Ink.text(13))
                        .foregroundStyle(Ink.faint)
                        .contentTransition(.opacity)
                        .animation(Ink.ease, value: model.status)
                        .accessibilityHidden(true)
                    Text(model.clock)
                        .font(Ink.digits(58))
                        .foregroundStyle(Ink.ink)
                        .contentTransition(.numericText(countsDown: !model.isStopwatch))
                        .animation(.snappy, value: model.shownSecond)
                        .animation(.snappy, value: model.mode)
                        .modifier(SpokenTimer())
                    ModeMark()
                    // A stopwatch has no cycle; the dots fade but keep their room.
                    CycleDots(filled: model.engine.cyclePosition, of: model.config.longBreakEvery)
                        .opacity(model.isStopwatch ? 0 : 1)
                        .animation(Ink.ease, value: model.mode)
                }
            }
            .frame(width: 270, height: 270)
            .contentShape(Circle())
            .onTapGesture(perform: model.switchMode)
            .pointerStyle(model.isActive ? nil : .link)
            .help(model.isActive ? "" : "switch to \(Copy.modeName(stopwatch: !model.isStopwatch))")

            tagField
                .padding(.top, 30)

            HStack(spacing: 28) {
                Button("reset", action: model.reset)
                    .buttonStyle(.inkLink)
                    .opacity(model.isActive ? 1 : 0)
                    .disabled(!model.isActive)
                Button(Copy.toggle(running: model.isRunning, active: model.isActive), action: model.toggle)
                    .buttonStyle(InkCapsuleStyle(minWidth: 128))
                    .keyboardShortcut(.defaultAction)
                Button("skip", action: model.skip)
                    .buttonStyle(.inkLink)
                    .opacity(model.isStopwatch ? 0 : 1)
                    .disabled(model.isStopwatch)
            }
            .padding(.top, 28)
        }
        .animation(Ink.ease, value: model.isActive)
        .animation(Ink.ease, value: model.mode)
    }

    private var tagField: some View {
        @Bindable var model = model
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("studying")
                    .font(Ink.text(15))
                    .foregroundStyle(Ink.faint)
                VStack(spacing: 3) {
                    // AppKit draws `prompt` in its own grey and weight; an
                    // overlay keeps the placeholder in the ink palette.
                    TextField("", text: $model.tag)
                        .textFieldStyle(.plain)
                        .font(Ink.text(15, .medium))
                        .foregroundStyle(Ink.ink)
                        .focused($tagFocused)
                        .onSubmit { tagFocused = false }
                        .tint(Ink.ink)
                        .frame(width: 150)
                        .background(alignment: .leading) {
                            if model.tag.isEmpty {
                                Text("anything").font(Ink.text(15)).foregroundStyle(Ink.ink.opacity(0.28))
                                    .allowsHitTesting(false)
                            }
                        }
                    Rectangle().fill(tagFocused ? Ink.faint : Ink.ghost).frame(height: 1)
                }
                .frame(width: 150)
            }
            let suggestions = model.recentTags.filter { $0 != model.tag.lowercased() }.prefix(4)
            HStack(spacing: 14) {
                ForEach(Array(suggestions), id: \.self) { tag in
                    Button(tag) { model.tag = tag }
                        .buttonStyle(.inkLink(selected: false, size: 12))
                }
            }
            .frame(height: 14)
        }
    }
}

/// Which timer this is, under the digits. Also the mode switch for the
/// keyboard and VoiceOver.
private struct ModeMark: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: model.switchMode) {
            Glyph(model.isStopwatch ? .stopwatch : .tomato, size: 18, boiling: model.isRunning, lineWidth: 1.5)
                .id(model.mode)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // Not .disabled: that would grey the mark mid-block. Switching
        // already waits for the block to end.
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.mode)
        .accessibilityLabel(Copy.modeName(stopwatch: model.isStopwatch))
        .accessibilityHint(model.isActive ? "" : "switches to \(Copy.modeName(stopwatch: !model.isStopwatch))")
    }
}

/// Progress through the long-break cycle.
private struct CycleDots: View {
    let filled: Int
    let of: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<of, id: \.self) { i in
                Circle()
                    .strokeBorder(Ink.faint, lineWidth: 1)
                    .background(Circle().fill(i < filled ? Ink.ink : .clear))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(Ink.ease, value: filled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(filled) of \(of)")
    }
}

/// VoiceOver: "focus, 12 minutes left" or "stopwatch, 12 minutes"; "paused, …" while paused.
struct SpokenTimer: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let amount = model.isStopwatch ? Copy.spokenCounted(model.shown) : Copy.spokenLeft(model.shown)
        content
            .accessibilityLabel(model.isStopwatch ? "stopwatch" : Copy.phaseName(model.phase))
            .accessibilityValue(model.isActive && !model.isRunning ? "paused, \(amount)" : amount)
    }
}
