import InkKit
import SwiftUI
import DrillCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(Sync.self) private var sync

    var body: some View {
        @Bindable var model = model
        @Bindable var sync = sync

        Form {
            Section {
                Picker("appearance", selection: $model.theme) {
                    ForEach(Theme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                minutes("focus", $model.config.focus, 5...120, step: 5)
                minutes("short break", $model.config.shortBreak, 1...30)
                minutes("long break", $model.config.longBreak, 5...60, step: 5)
                Stepper(value: $model.config.longBreakEvery, in: 2...8) {
                    row("long break every", "\(model.config.longBreakEvery)")
                }
            }
            Section("intervals") {
                minutes("run", $model.intervalConfig.run, 1...60)
                minutes("walk", $model.intervalConfig.walk, 1...60)
            }
            Section {
                Stepper(value: goalMinutes, in: 0...720, step: 30) {
                    row("daily goal", Copy.goal(model.dailyGoal))
                }
            }
            Section {
                Toggle("auto-start breaks", isOn: $model.config.autoStartBreaks)
                Toggle("auto-start focus", isOn: $model.config.autoStartFocus)
                Toggle("sound", isOn: $model.soundOn)
            }
            Section {
                AccountRow()
                if sync.isSignedIn {
                    Toggle("auto sync", isOn: $sync.autoSync)
                }
            }
            if updater.isEnabled {
                Section { UpdateRow() }
            }
            Section("plugins") {
                Text("coming soon.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Ink.paper)
        .tint(Ink.ink)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // Drop the system's "Drill Settings" title; the app speaks lowercase.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private func minutes(_ label: String, _ seconds: Binding<TimeInterval>,
                         _ range: ClosedRange<Int>, step: Int = 1) -> some View {
        let value = Binding<Int>(
            get: { Int(seconds.wrappedValue / 60) },
            set: { seconds.wrappedValue = TimeInterval($0 * 60) })
        return Stepper(value: value, in: range, step: step) {
            row(label, "\(value.wrappedValue) min")
        }
    }

    private var goalMinutes: Binding<Int> {
        Binding(get: { Int(model.dailyGoal / 60) }, set: { model.dailyGoal = TimeInterval($0 * 60) })
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

private struct UpdateRow: View {
    @Environment(Updater.self) private var updater
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("version \(updater.current?.description ?? "?")")
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                UpdateMark(state: updater.state)
                switch updater.state {
                case .checking:
                    Text("checking…").foregroundStyle(.secondary)
                case .installing:
                    Text("updating…").foregroundStyle(.secondary)
                case .available(let release):
                    Button("update to \(release.version.description)") { Task { await updater.install() } }
                        .disabled(model.isActive)
                default:
                    Button("check") { Task { await updater.check() } }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: updater.state)
        .onAppear { updater.checkIfStale() }
    }

    private var note: String? {
        switch updater.state {
        case .upToDate: "you're up to date."
        case .available: model.isActive ? "finish this block first. updating restarts the app." : "an update is available."
        case .failed(let message): message
        default: nil
        }
    }
}

private struct UpdateMark: View {
    let state: Updater.State

    var body: some View {
        StatusMark(status: status)
    }

    private var status: StatusMark.Status {
        switch state {
        case .checking, .installing: .working
        case .upToDate: .done
        case .available: .pending
        default: .none
        }
    }
}

private struct AccountRow: View {
    @Environment(Sync.self) private var sync
    @State private var signingIn = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sync.account?.username ?? "sync")
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            if sync.isSignedIn {
                Button("sign out", action: sync.signOut)
            } else {
                Button("sign in") { signingIn = true }
            }
        }
        .sheet(isPresented: $signingIn) { AccountSheet() }
    }

    private var note: String {
        switch sync.state {
        case .signedOut: "sign in to sync across devices."
        case .syncing: "syncing…"
        case .idle: "synced."
        case .offline: "offline. your sessions are safe here."
        }
    }
}
