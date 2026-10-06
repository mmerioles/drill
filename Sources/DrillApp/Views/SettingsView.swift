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
private struct UpdateRow: View {
    @Environment(Updater.self) private var updater
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("version \(updater.current?.description ?? "?")")
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
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

    private var note: String? {
        switch updater.state {
        case .upToDate: "you're up to date."
        case .available: model.isActive ? "finish this block first. updating restarts the app." : nil
        case .failed(let message): message
        default: nil
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
                Text(sync.account?.email ?? "sync")
                Text(note).font(.caption).foregroundStyle(.secondary)
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
        case .signedOut: "sign in to keep your sessions on every device."
        case .syncing: "syncing…"
        case .idle: "synced."
        case .offline: "can't reach the server. sessions stay here until it's back."
        case .unconfirmed: "confirm your email to start syncing. check your inbox."
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
            TextField("server", text: $text, prompt: Text(Sync.defaultServer == nil ? "" : "drill's"))
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
        return Sync.defaultServer == nil
            ? "put in your own server to self-host." : "leave empty to use ours, or put in your own to self-host."
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
