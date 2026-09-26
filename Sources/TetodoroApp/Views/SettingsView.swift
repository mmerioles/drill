import InkKit
import SwiftUI
import TetodoroCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("look") {
                Picker("theme", selection: $model.theme) {
                    ForEach(Theme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("teto is light: off-white and greys with her red. ink is dark and pure black and white.")
                    .font(Ink.text(12))
                    .foregroundStyle(Ink.faint)
            }
            Section("lengths") {
                minutes("focus", \.focus, 5...120, step: 5)
                minutes("short break", \.shortBreak, 1...30)
                minutes("long break", \.longBreak, 5...60, step: 5)
                Stepper(value: $model.config.longBreakEvery, in: 2...8) {
                    row("long break every", "\(model.config.longBreakEvery) focus blocks")
                }
            }
            Section("flow") {
                Toggle("start breaks automatically", isOn: $model.config.autoStartBreaks)
                Toggle("start focus after a break automatically", isOn: $model.config.autoStartFocus)
                Toggle("play a sound when a phase ends", isOn: $model.soundOn)
            }
            Section {
                Text("changes apply from the next phase. sessions are kept on this mac for now — sync to your own server is on the way.")
                    .font(Ink.text(12))
                    .foregroundStyle(Ink.faint)
            }
        }
        .formStyle(.grouped)
        .tint(Ink.ink)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func minutes(_ label: String, _ key: WritableKeyPath<TimerConfig, TimeInterval>,
                         _ range: ClosedRange<Int>, step: Int = 1) -> some View {
        let value = Binding<Int>(
            get: { Int(model.config[keyPath: key] / 60) },
            set: { model.config[keyPath: key] = TimeInterval($0 * 60) })
        return Stepper(value: value, in: range, step: step) {
            row(label, "\(value.wrappedValue) min")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
