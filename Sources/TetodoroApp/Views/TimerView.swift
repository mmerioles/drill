import InkKit
import SwiftUI
import TetodoroCore

/// The ring, the numbers, what you're studying, and the three controls.
struct TimerView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var tagFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ZStack {
                DoodleRing(progress: model.progress, boiling: model.isRunning)
                VStack(spacing: 8) {
                    // A single quiet word, only when there's something to say;
                    // the fixed height keeps the digits from jumping.
                    Text(Copy.status(model.phase, running: model.isRunning, active: model.isActive) ?? " ")
                        .font(Ink.text(13))
                        .foregroundStyle(Ink.faint)
                        .contentTransition(.opacity)
                        .animation(Ink.ease, value: model.phase)
                    Text(Copy.clock(model.remaining))
                        .font(Ink.digits(58))
                        .foregroundStyle(Ink.ink)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: Int(model.remaining.rounded(.up)))
                    CycleDots(filled: model.engine.cyclePosition, of: model.config.longBreakEvery)
                }
            }
            .frame(width: 270, height: 270)

            tagField
                .padding(.top, 30)

            HStack(spacing: 28) {
                Button("reset", action: model.reset)
                    .buttonStyle(.inkLink)
                    .opacity(model.isActive ? 1 : 0)
                    .disabled(!model.isActive)
                Button(model.isRunning ? "pause" : (model.isActive ? "resume" : "start"), action: model.toggle)
                    .buttonStyle(.inkCapsule)
                    .keyboardShortcut(.defaultAction)
                    .frame(minWidth: 150)
                Button("skip", action: model.skip)
                    .buttonStyle(.inkLink)
            }
            .padding(.top, 28)
        }
        .animation(Ink.ease, value: model.isActive)
    }

    private var tagField: some View {
        @Bindable var model = model
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("studying")
                    .font(Ink.text(15))
                    .foregroundStyle(Ink.faint)
                VStack(spacing: 3) {
                    TextField("", text: $model.tag, prompt: Text("anything").foregroundStyle(Ink.ghost))
                        .textFieldStyle(.plain)
                        .font(Ink.text(15, .medium))
                        .foregroundStyle(Ink.ink)
                        .focused($tagFocused)
                        .onSubmit { tagFocused = false }
                        .tint(Ink.ink)
                        .frame(width: 150)
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

/// Where you are in the long-break cycle: small inked dots, filled as you go.
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
    }
}
