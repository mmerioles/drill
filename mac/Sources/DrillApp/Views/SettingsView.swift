import InkKit
import SwiftUI
import DrillCore

/// Groups of 44-tall rows, like the other sheets: label left, value and
/// control right.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(Sync.self) private var sync

    var body: some View {
        @Bindable var model = model
        @Bindable var sync = sync

        VStack(alignment: .leading, spacing: 24) {
            Text("settings")
                .font(Ink.text(20, .semibold))
                .foregroundStyle(Ink.ink)
                .padding(.bottom, -8)

            group {
                row("appearance") {
                    Picker("", selection: $model.theme) {
                        ForEach(Theme.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            group {
                minutes("focus", $model.config.focus, 5...120, step: 5)
                rule
                minutes("short break", $model.config.shortBreak, 1...30)
                rule
                minutes("long break", $model.config.longBreak, 5...60, step: 5)
                rule
                stepper("long break every", "\(model.config.longBreakEvery)",
                        value: $model.config.longBreakEvery, in: 2...8)
                rule
                stepper("daily goal", Copy.goal(model.dailyGoal), value: goalMinutes, in: 0...720, step: 30)
            }
            group("intervals") {
                minutes("run", $model.intervalConfig.run, 1...60)
                rule
                minutes("walk", $model.intervalConfig.walk, 1...60)
            }
            group {
                toggle("auto-start breaks", $model.config.autoStartBreaks)
                rule
                toggle("auto-start focus", $model.config.autoStartFocus)
                rule
                toggle("sound", $model.soundOn)
            }
            group {
                AccountRow()
                if sync.isSignedIn {
                    rule
                    toggle("auto sync", $sync.autoSync)
                }
            }
            if updater.isEnabled {
                group { UpdateRow() }
            }
            group("plugins") {
                row("coming soon.") { EmptyView() }
                    .foregroundStyle(Ink.faint)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Ink.paper)
        .tint(Ink.ink)
        // Drop the system's "Drill Settings" title; the app speaks lowercase.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private func minutes(_ label: String, _ seconds: Binding<TimeInterval>,
                         _ range: ClosedRange<Int>, step: Int = 1) -> some View {
        let value = Binding<Int>(
            get: { Int(seconds.wrappedValue / 60) },
            set: { seconds.wrappedValue = TimeInterval($0 * 60) })
        return stepper(label, "\(value.wrappedValue) min", value: value, in: range, step: step)
    }

    private var goalMinutes: Binding<Int> {
        Binding(get: { Int(model.dailyGoal / 60) }, set: { model.dailyGoal = TimeInterval($0 * 60) })
    }

    private func stepper(_ label: String, _ shown: String, value: Binding<Int>,
                         in range: ClosedRange<Int>, step: Int = 1) -> some View {
        row(label) {
            Text(shown).monospacedDigit().foregroundStyle(Ink.faint)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(label)
        }
    }

    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        row(label) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(label)
        }
    }
}

/// A label and, to the right, its value and control.
private func row(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
    HStack(spacing: 12) {
        Text(label)
        Spacer(minLength: 16)
        trailing()
    }
    .font(Ink.text(15))
    .foregroundStyle(Ink.ink)
    .frame(minHeight: 44)
}

/// Rows in a wash, with an optional small title over it.
private func group(_ title: String? = nil, @ViewBuilder _ rows: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        if let title {
            Text(title).font(Ink.text(13)).foregroundStyle(Ink.faint)
        }
        VStack(spacing: 0, content: rows)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.ink.opacity(0.045)))
    }
}

/// The hairline between rows.
private var rule: some View {
    Rectangle().fill(Ink.ghost).frame(height: 1)
}

private struct UpdateRow: View {
    @Environment(Updater.self) private var updater
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("version \(updater.current?.description ?? "?")")
                if let note {
                    Text(note).font(Ink.text(13)).foregroundStyle(Ink.faint)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                UpdateMark(state: updater.state)
                switch updater.state {
                case .checking:
                    Text("checking…").foregroundStyle(Ink.faint)
                case .installing:
                    Text("updating…").foregroundStyle(Ink.faint)
                case .available(let release):
                    Button("update to \(release.version.description)") { Task { await updater.install() } }
                        .disabled(model.isActive)
                default:
                    Button("check") { Task { await updater.check() } }
                }
            }
            .buttonStyle(.inkLink(selected: false, size: 15))
        }
        .font(Ink.text(15))
        .foregroundStyle(Ink.ink)
        .frame(minHeight: 44)
        .padding(.vertical, note == nil ? 0 : 6)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sync.account?.username ?? "sync")
                Text(note).font(Ink.text(13)).foregroundStyle(Ink.faint)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 16)
            if sync.isSignedIn {
                Button("sign out", action: sync.signOut)
            } else {
                Button("sign in") { signingIn = true }
            }
        }
        .buttonStyle(.inkLink(selected: false, size: 15))
        .font(Ink.text(15))
        .foregroundStyle(Ink.ink)
        .frame(minHeight: 44)
        .padding(.vertical, 6)
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
