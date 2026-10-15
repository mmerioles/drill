import DrillCore
import InkKit
import SwiftUI

/// Sign in or make an account, from settings.
struct AccountSheet: View {
    var preview: AccountForm.Preview = .none
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AccountForm(preview: preview, creating: preview != .none, titled: true,
                    cancel: { dismiss() }, done: { dismiss() })
            .padding(24)
            .frame(width: 440)
            .background(Ink.paper)
    }
}

/// Sign in or make an account: a username and a password. In the settings
/// sheet and on the welcome screen.
struct AccountForm: View {
    /// For --render, which can't type.
    enum Preview { case none, available, taken }

    @Environment(Sync.self) private var sync

    @State private var creating: Bool
    @State private var username: String
    @State private var password: String
    @State private var confirm: String
    @State private var check: Check
    @State private var checking: Task<Void, Never>?
    @State private var problem: String?
    @State private var working = false
    @State private var staySignedIn = true
    @FocusState private var focused: Field?

    private let preview: Preview
    private let titled: Bool
    private let cancel: (() -> Void)?
    private let done: () -> Void
    private enum Field { case username, password, confirm }
    /// What the live check last said about the name in the field.
    private enum Check: Equatable { case none, checking, available, taken }

    init(preview: Preview = .none, creating: Bool, titled: Bool, cancel: (() -> Void)?, done: @escaping () -> Void) {
        self.preview = preview
        self.titled = titled
        self.cancel = cancel
        self.done = done
        let filled = preview != .none
        _creating = State(initialValue: creating)
        _username = State(initialValue: filled ? "teto" : "")
        _password = State(initialValue: filled ? "kasane-0401" : "")
        _confirm = State(initialValue: filled ? "kasane-0401" : "")
        _check = State(initialValue: preview == .available ? .available : preview == .taken ? .taken : .none)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if titled {
                Text(creating ? "make an account" : "sign in")
                    .font(Ink.text(20, .semibold))
                    .foregroundStyle(Ink.ink)
            }

            fields {
                row("username") {
                    TextField("", text: $username)
                        .focused($focused, equals: .username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    if creating {
                        StatusMark(status: mark)
                            .help(usernameProblem ?? "")
                            .accessibilityLabel(usernameProblem ?? "")
                    }
                }
                Divider().overlay(Ink.ghost)
                row("password") {
                    SecureField("", text: $password)
                        .focused($focused, equals: .password)
                        .textContentType(creating ? .newPassword : .password)
                }
                if creating {
                    Divider().overlay(Ink.ghost)
                    row("confirm") {
                        SecureField("", text: $confirm)
                            .focused($focused, equals: .confirm)
                            .textContentType(.newPassword)
                    }
                    hint(confirmHint)
                }
                Divider().overlay(Ink.ghost)
                row("stay signed in") {
                    Spacer()
                    Toggle("", isOn: $staySignedIn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("stay signed in")
                }
            }

            message(problem ?? (creating ? "password needs 8+ characters." : " "))

            HStack {
                Button(creating ? "have an account?" : "new here?") {
                    creating.toggle()
                    problem = nil
                }
                .buttonStyle(.inkLink(selected: false, size: 15))
                Spacer()
                if let cancel {
                    Button("cancel", action: cancel)
                        .buttonStyle(.inkLink(selected: false, size: 15))
                        .keyboardShortcut(.cancelAction)
                }
                primary(creating ? "create account" : "sign in", ready: ready, action: submit)
            }
        }
        .textFieldStyle(.plain)
        .onAppear { focused = .username }
        .onChange(of: username) { _, text in
            let clean = Username.clean(text)
            if clean != text { username = clean } else { recheck() }
        }
        .onChange(of: creating) { _, _ in recheck() }
    }

    // MARK: The live check

    /// 300 ms after the last keystroke, asks whether the name is free.
    /// Typing again drops the question in flight.
    private func recheck() {
        checking?.cancel()
        guard creating, preview == .none, Username.isValid(username) else {
            check = .none
            return
        }
        check = .checking
        let name = username
        checking = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let free = try? await sync.usernameAvailable(name)
            guard !Task.isCancelled, username == name else { return }
            check = free.map { $0 ? .available : .taken } ?? .none
        }
    }

    private var mark: StatusMark.Status {
        switch check {
        case .none: creating && !username.isEmpty && !Username.isValid(username) ? .failed : .none
        case .checking: .working
        case .available: .done
        case .taken: .failed
        }
    }

    /// What the red cross means, for hover and VoiceOver; the cross alone says it on screen.
    private var usernameProblem: String? {
        guard creating, !username.isEmpty else { return nil }
        if !Username.isValid(username) { return Username.hint }
        return check == .taken ? "taken" : nil
    }

    private var confirmHint: String? {
        !password.isEmpty && !confirm.isEmpty && password != confirm ? "passwords don't match" : nil
    }

    private var ready: Bool {
        if creating {
            return check == .available && password.count >= 8 && confirm == password
        }
        return !username.isEmpty && !password.isEmpty
    }

    private func submit() {
        run {
            if creating {
                try await sync.createAccount(username: username, password: password, staySignedIn: staySignedIn)
            } else {
                try await sync.signIn(username: username, password: password, staySignedIn: staySignedIn)
            }
            done()
        }
    }

    // MARK: Pieces

    /// Runs one call at a time, and shows what went wrong.
    private func run(_ work: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        problem = nil
        Task {
            do {
                try await work()
            } catch let error as Sync.Problem {
                problem = error.message
            } catch {
                problem = "something went wrong. try again."
            }
            working = false
        }
    }

    private func fields(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.ink.opacity(0.045)))
    }

    private func row(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(Ink.ink)
            field().multilineTextAlignment(.trailing)
        }
        .font(Ink.text(15))
        .frame(minHeight: 44)
    }

    /// A small note right under a row, when there's something to say.
    @ViewBuilder private func hint(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(Ink.text(13))
                .foregroundStyle(Ink.faint)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, -8)
                .padding(.bottom, 10)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Ink.text(13))
            .foregroundStyle(Ink.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primary(_ title: String, ready: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(InkCapsuleStyle(size: 14, height: 40))
            .fixedSize()
            .keyboardShortcut(.defaultAction)
            .disabled(!ready || working)
            .opacity(ready && !working ? 1 : 0.5)
            .padding(.leading, 12)
    }
}
