import InkKit
import SwiftUI
import DrillCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater

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
            Section {
                AccountRow()
                ServerRow()
            }
            if updater.isEnabled {
                Section { UpdateRow() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Ink.paper)
        .tint(Ink.ink)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // The system titles this window "Drill Settings"; the app speaks
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

/// The version you're on, and one button that does the next sensible thing.
/// A mark beside it says how the last check went: a spinner while looking,
/// a green check when current, a yellow dot when there's something newer.
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

/// Who you're syncing as, with a way in or out.
private struct AccountRow: View {
    @Environment(Sync.self) private var sync
    @State private var signingIn = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sync.account?.email ?? sync.waiting?.email ?? "sync")
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            if let waiting = sync.waiting {
                StatusMark(status: waiting.confirmed ? .done : .pending, breathing: true)
            }
            if sync.waiting?.confirmed == false {
                Button("cancel", action: sync.stopWaiting)
            } else if sync.isSignedIn {
                Button("sign out", action: sync.signOut)
            } else {
                Button("sign in") { signingIn = true }
            }
        }
        .sheet(isPresented: $signingIn) { AccountSheet() }
        .animation(.easeInOut(duration: 0.25), value: sync.waiting)
    }

    private var note: String {
        if let waiting = sync.waiting {
            return waiting.confirmed ? "you're in." : "check your inbox for the link."
        }
        return switch sync.state {
        case .signedOut: "sign in to sync across devices."
        case .syncing: "syncing…"
        case .idle: "synced."
        case .offline: "offline. your sessions are safe here."
        case .unconfirmed: "confirm your email to start syncing."
        }
    }
}

/// Our server by default; self-hosters put their own address here.
private struct ServerRow: View {
    @Environment(Sync.self) private var sync
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("server", text: $text, prompt: Text("drill's"))
                .multilineTextAlignment(.trailing)
                .disabled(sync.isSignedIn)
                .onSubmit(save)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { text = sync.customServer ?? "" }
    }

    private var note: String {
        if let problem { return problem }
        if sync.isSignedIn { return "sign out to change servers." }
        return "leave blank to use ours, or add your own."
    }

    private func save() {
        do {
            try sync.setServer(text)
            text = sync.customServer ?? ""
            problem = nil
        } catch let error as Sync.Problem {
            problem = error.message
        } catch {}
    }
}
