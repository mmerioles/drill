import DrillCore
import InkKit
import SwiftUI

/// Sign in or make an account, from settings.
struct AccountSheet: View {
    var preview: AccountForm.Preview = .none
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AccountForm(preview: preview, titled: true, cancel: { dismiss() }, done: { dismiss() })
            .padding(24)
            .frame(width: 440)
            .background(Ink.paper)
    }
}

/// Sign in or make an account: a username and a password. In the settings
/// sheet and on the welcome screen; opens on sign in.
struct AccountForm: View {
    /// For --render, which can't type: a filled-in create form.
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

    init(preview: Preview = .none, titled: Bool, cancel: (() -> Void)?, done: @escaping () -> Void) {
        self.preview = preview
        self.titled = titled
        self.cancel = cancel
        self.done = done
        let filled = preview != .none
        _creating = State(initialValue: filled)
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
                row(mark: usernameMark, meaning: usernameProblem) {
                    TextField("username", text: $username)
                        .focused($focused, equals: .username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                }
                Divider().overlay(Ink.ghost)
                row(mark: passwordMark, meaning: passwordMark == .failed ? Password.hint : nil) {
                    SecureField("password", text: $password)
                        .focused($focused, equals: .password)
                        .textContentType(creating ? .newPassword : .password)
                }
                if creating {
                    Divider().overlay(Ink.ghost)
                    row(mark: confirmMark, meaning: confirmMark == .failed ? "doesn't match" : nil) {
                        SecureField("confirm password", text: $confirm)
                            .focused($focused, equals: .confirm)
                            .textContentType(.newPassword)
                    }
                }
                Divider().overlay(Ink.ghost)
                HStack {
                    Text("stay signed in").foregroundStyle(Ink.ink)
                    Spacer()
                    Toggle("", isOn: $staySignedIn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("stay signed in")
                }
                .font(Ink.text(15))
                .frame(minHeight: 44)
            }

            message(problem ?? " ")

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
        .onChange(of: [username, password, confirm]) { _, _ in problem = nil }
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

    private var usernameMark: StatusMark.Status {
        guard creating else { return .none }
        return switch check {
        case .none: !username.isEmpty && !Username.isValid(username) ? .failed : .none
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

    private var passwordMark: StatusMark.Status {
        guard creating, !password.isEmpty else { return .none }
        return Password.isValid(password) ? .done : .failed
    }

    private var confirmMark: StatusMark.Status {
        guard creating, !confirm.isEmpty else { return .none }
        return Password.confirms(confirm, password) ? .done : .failed
    }

    private var ready: Bool {
        if creating {
            return usernameMark == .done && passwordMark == .done && confirmMark == .done
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

    /// A field, and its mark at the trailing edge; `meaning` says what a cross means,
    /// for hover and VoiceOver.
    private func row(mark: StatusMark.Status, meaning: String?, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 12) {
            field()
            if creating {
                StatusMark(status: mark)
                    .help(meaning ?? "")
                    .accessibilityLabel(meaning ?? "")
                    .accessibilityHidden(mark == .none)
            }
        }
        .font(Ink.text(15))
        .frame(minHeight: 44)
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
