import InkKit
import SwiftUI

/// Sign in, or make an account: a server, an email and a password.
struct AccountSheet: View {
    @Environment(Sync.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var creating = false
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var working = false
    @FocusState private var focused: Field?

    private enum Field { case server, email, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(creating ? "create an account" : "sign in to sync")
                .font(Ink.word(20))
                .foregroundStyle(Ink.ink)

            VStack(spacing: 0) {
                row("server") {
                    TextField("", text: $server, prompt: Text("tetodoro.example.com"))
                        .focused($focused, equals: .server)
                        .textContentType(.URL)
                }
                Divider().overlay(Ink.ghost)
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
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.ink.opacity(0.045)))

            Text(problem ?? " ")
                .font(Ink.text(13))
                .foregroundStyle(Ink.faint)

            HStack {
                Button(creating ? "i have an account" : "create an account") {
                    creating.toggle()
                    problem = nil
                }
                .buttonStyle(.inkLink(selected: false, size: 13))
                Spacer()
                Button("cancel") { dismiss() }
                    .buttonStyle(.inkLink(selected: false, size: 13))
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "create" : "sign in", action: submit)
                    .buttonStyle(InkCapsuleStyle(size: 14))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || working)
                    .opacity(ready && !working ? 1 : 0.5)
                    .padding(.leading, 12)
            }
        }
        .textFieldStyle(.plain)
        .padding(28)
        .frame(width: 400)
        .background(Ink.paper)
        .onAppear {
            server = sync.server
            focused = server.isEmpty ? .server : .email
        }
    }

    private var ready: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@") && password.count >= 8
    }

    private func row(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(Ink.ink)
            field().multilineTextAlignment(.trailing)
        }
        .font(Ink.text(14))
        .frame(minHeight: 42)
    }

    private func submit() {
        guard ready, !working else { return }
        working = true
        problem = nil
        Task {
            do {
                try await sync.signIn(server: server, email: email, password: password, create: creating)
                dismiss()
            } catch let error as Sync.Problem {
                problem = error.message
            } catch {
                problem = "something went wrong. try again."
            }
            working = false
        }
    }
}
