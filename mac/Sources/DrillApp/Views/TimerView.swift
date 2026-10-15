import InkKit
import SwiftUI
import DrillCore

/// Everything inside the face, sized from the ring's diameter R so the
/// readout keeps its proportion on every platform.
enum Ring {
    static let size: CGFloat = 270
    /// Status word, 0.055 R; its line is kept even when there's nothing to say.
    static let status = (size * 0.055).rounded()
    static let statusLine: CGFloat = 18
    static let statusGap = (size * 0.03).rounded()
    /// The numerals, 0.22 R.
    static let clock = (size * 0.22).rounded()
    static let slotGap = (size * 0.04).rounded()
    /// The mark, 0.08 R, with the cycle dots or the round line 4 under it.
    static let mark = (size * 0.08).rounded()
    static let round = (size * 0.055).rounded()
    static let roundLine: CGFloat = 18
    /// Fixed, so the digits never move between modes.
    static let slot = mark + 4 + roundLine
}

/// The ring, digits, tag field and controls. Between blocks, clicking the
/// face cycles pomodoro → stopwatch → intervals.
struct TimerView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var tagFocused: Bool
    @Environment(\.paletteOpen) private var paletteOpen

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ZStack {
                DoodleRing(progress: model.progress, boiling: model.isRunning)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    // A single quiet word, only when there's something to say;
                    // the fixed height keeps the digits from jumping.
                    Text(model.status ?? " ")
                        .font(Ink.text(Ring.status))
                        .foregroundStyle(Ink.faint)
                        .frame(height: Ring.statusLine)
                        .contentTransition(.opacity)
                        .animation(Ink.ease, value: model.status)
                        .accessibilityHidden(true)
                    Text(model.clock)
                        .font(Ink.digits(Ring.clock))
                        .foregroundStyle(Ink.ink)
                        .padding(.top, Ring.statusGap)
                        .contentTransition(.numericText(countsDown: !model.isStopwatch))
                        .animation(.snappy, value: model.shownSecond)
                        .animation(.snappy, value: model.mode)
                        .modifier(SpokenTimer())
                    VStack(spacing: 4) {
                        ModeMark()
                        // Only the pomodoro has a cycle; the dots fade but keep
                        // their room, which intervals borrow for the round.
                        ZStack {
                            CycleDots(filled: model.engine.cyclePosition, of: model.config.longBreakEvery)
                                .opacity(model.mode == .pomodoro ? 1 : 0)
                            Text(model.roundLine ?? " ")
                                .font(Ink.text(Ring.round))
                                .foregroundStyle(Ink.faint)
                                .fixedSize()
                                .opacity(model.roundLine == nil ? 0 : 1)
                                .contentTransition(.numericText())
                                .animation(Ink.ease, value: model.roundLine)
                        }
                        .frame(height: Ring.roundLine)
                        .animation(Ink.ease, value: model.mode)
                    }
                    .frame(height: Ring.slot)
                    .padding(.top, Ring.slotGap)
                }
            }
            .frame(width: Ring.size, height: Ring.size)
            .contentShape(Circle())
            .onTapGesture(perform: model.switchMode)
            .pointerStyle(model.isActive ? nil : .link)
            .help(model.isActive ? "" : "switch to \(Copy.modeName(model.mode.next))")

            // A workout has no tag; the field fades but keeps its room.
            tagField
                .padding(.top, 40)
                .opacity(model.isIntervals ? 0 : 1)
                .allowsHitTesting(!model.isIntervals)
                .accessibilityHidden(model.isIntervals)

            HStack(spacing: 32) {
                Button(Copy.reset(intervals: model.isIntervals), action: model.reset)
                    .buttonStyle(.inkLink(selected: false, size: 15))
                    .frame(minHeight: 44)
                    .opacity(model.isActive ? 1 : 0)
                    .disabled(!model.isActive)
                Button(Copy.toggle(running: model.isRunning, active: model.isActive), action: model.toggle)
                    .buttonStyle(InkCapsuleStyle(minWidth: 128))
                    .keyboardShortcut(paletteOpen ? nil : .defaultAction)
                Button("skip", action: model.skip)
                    .buttonStyle(.inkLink(selected: false, size: 15))
                    .frame(minHeight: 44)
                    .opacity(model.isStopwatch ? 0 : 1)
                    .disabled(model.isStopwatch)
            }
            .padding(.top, 32)
        }
        .animation(Ink.ease, value: model.isActive)
        .animation(Ink.ease, value: model.mode)
    }

    private var tagField: some View {
        @Bindable var model = model
        return VStack(spacing: 8) {
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
            .frame(height: 32)
            let suggestions = model.recentTags.filter { $0 != model.tag.lowercased() && $0 != Copy.intervalsTag }.prefix(4)
            HStack(spacing: 16) {
                ForEach(Array(suggestions), id: \.self) { tag in
                    Button(tag) { model.tag = tag }
                        .buttonStyle(.inkLink(selected: false, size: 13))
                }
            }
            .frame(height: 16)
        }
    }
}

/// Which timer this is, under the digits. Also the mode switch for the
/// keyboard and VoiceOver.
private struct ModeMark: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: model.switchMode) {
            Glyph(model.mark, size: Ring.mark, boiling: model.isRunning, lineWidth: 1.6)
                .id(model.mark)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // Not .disabled: that would grey the mark mid-block. Switching
        // already waits for the block to end.
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.mark)
        .accessibilityLabel(Copy.modeName(model.mode))
        .accessibilityHint(model.isActive ? "" : "switches to \(Copy.modeName(model.mode.next))")
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
            .accessibilityLabel(label)
            .accessibilityValue(model.isActive && !model.isRunning ? "paused, \(amount)" : amount)
    }

    private var label: String {
        switch model.mode {
        case .pomodoro: Copy.phaseName(model.phase)
        case .stopwatch: "stopwatch"
        case .intervals: Copy.phaseName(model.intervals.phase)
        }
    }
}
