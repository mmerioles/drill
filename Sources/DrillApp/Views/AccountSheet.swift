import InkKit
import SwiftUI

/// Sign in, or make an account: an email and a password, then a click on
/// the link in the confirmation email, which the sheet notices by itself.
/// The server is ours unless settings name a self-hosted one.
struct AccountSheet: View {
    @Environment(Sync.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var creating = false
    @State private var email = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var note: String?
    @State private var working = false
    @FocusState private var focused: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let waiting = sync.waiting {
                waitingForLink(waiting)
                    .transition(.opacity)
            } else {
                details
                    .transition(.opacity)
            }
        }
        .textFieldStyle(.plain)
        .padding(28)
        .frame(width: 400)
        .background(Ink.paper)
        .animation(.easeInOut(duration: 0.25), value: sync.waiting == nil)
        .onAppear {
            if let waiting = sync.waiting { email = waiting.email } else { focused = .email }
        }
        // Once the link is clicked: a beat on the check mark, then out.
        .onChange(of: sync.waiting?.confirmed) { _, confirmed in
            guard confirmed == true else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                dismiss()
            }
        }
    }

    // MARK: Email and password

    @ViewBuilder private var details: some View {
        Text(creating ? "create an account" : "sign in to sync")
            .font(Ink.word(20))
            .foregroundStyle(Ink.ink)

        fields {
            row("email") {
                TextField("", text: $email)
                    .focused($focused, equals: .email)
                    .textContentType(.username)
            }
            Divider().overlay(Ink.ghost)
            row("password") {
                SecureField("", text: $password)
                    .focused($focused, equals: .password)
                    .textContentType(creating ? .newPassword : .password)
            }
        }

        message(problem ?? (creating ? "at least 8 characters. we'll email you a link to confirm." : " "))

        HStack {
            Button(creating ? "i have an account" : "create an account") {
                creating.toggle()
                problem = nil
            }
            .buttonStyle(.inkLink(selected: false, size: 13))
            Spacer()
            cancel
            primary(creating ? "create" : "sign in", ready: detailsReady, action: submit)
        }
    }

    private var detailsReady: Bool {
        email.contains("@") && password.count >= 8
    }

    private func submit() {
        run {
            note = nil
            if creating {
                try await sync.createAccount(email: trimmedEmail, password: password)
            } else {
                try await sync.signIn(email: trimmedEmail, password: password)
            }
            if sync.waiting == nil { dismiss() }
        }
    }

    // MARK: Waiting on the email link

    @ViewBuilder private func waitingForLink(_ waiting: Sync.Waiting) -> some View {
        HStack(spacing: 10) {
            Text(waiting.confirmed ? "you're in" : "check your email")
                .font(Ink.word(20))
                .foregroundStyle(Ink.ink)
                .contentTransition(.opacity)
            Spacer()
            StatusMark(status: waiting.confirmed ? .done : .pending, breathing: true)
                .scaleEffect(1.5)
        }

        message(waiting.confirmed
            ? "confirmed. syncing now."
            : note ?? "we sent a link to \(waiting.email). click it, and this moves along by itself.")
            .contentTransition(.opacity)

        message(problem ?? " ")

        HStack(spacing: 16) {
            Button("wrong email?") {
                sync.stopWaiting()
                problem = nil
                focused = .email
            }
            .buttonStyle(.inkLink(selected: false, size: 13))
            Button("send it again", action: resend)
                .buttonStyle(.inkLink(selected: false, size: 13))
                .disabled(working)
            Spacer()
            // Closing keeps waiting; settings shows how it's going.
            Button("close") { dismiss() }
                .buttonStyle(.inkLink(selected: false, size: 13))
                .keyboardShortcut(.cancelAction)
        }
        .opacity(waiting.confirmed ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: waiting.confirmed)
    }

    private func resend() {
        run {
            try await sync.resendLink()
            if let email = sync.waiting?.email { note = "sent another link to \(email)." }
        }
    }

    // MARK: Pieces

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        .font(Ink.text(14))
        .frame(minHeight: 42)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Ink.text(13))
            .foregroundStyle(Ink.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cancel: some View {
        Button("cancel") { dismiss() }
            .buttonStyle(.inkLink(selected: false, size: 13))
            .keyboardShortcut(.cancelAction)
    }

    private func primary(_ title: String, ready: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(InkCapsuleStyle(size: 14))
            .keyboardShortcut(.defaultAction)
            .disabled(!ready || working)
            .opacity(ready && !working ? 1 : 0.5)
            .padding(.leading, 12)
    }
}
