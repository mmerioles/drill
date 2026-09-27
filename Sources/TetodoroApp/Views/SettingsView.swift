import InkKit
import SwiftUI
import TetodoroCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("appearance", selection: $model.theme) {
                    ForEach(Theme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                minutes("focus", \.focus, 5...120, step: 5)
                minutes("short break", \.shortBreak, 1...30)
                minutes("long break", \.longBreak, 5...60, step: 5)
                Stepper(value: $model.config.longBreakEvery, in: 2...8) {
                    row("long break every", "\(model.config.longBreakEvery)")
                }
            }
            Section {
                Toggle("auto-start breaks", isOn: $model.config.autoStartBreaks)
                Toggle("auto-start focus", isOn: $model.config.autoStartFocus)
                Toggle("sound", isOn: $model.soundOn)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Ink.paper)
        .tint(Ink.ink)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // The system titles this window "Tetodoro Settings"; the app speaks
        // in lowercase, so the title goes and the paper runs to the top.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
