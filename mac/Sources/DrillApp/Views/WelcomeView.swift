import InkKit
import SwiftUI

/// First launch, and after signing out: make an account, sign in, or go on
/// without one. Takes the timer's place in the main window.
struct WelcomeView: View {
    var preview: AccountForm.Preview = .none
    @Environment(Sync.self) private var sync

    var body: some View {
        VStack(spacing: 0) {
            Glyph(.drill, size: 34, tint: Ink.accent)
            Text("drill")
                .font(Ink.word(40))
                .foregroundStyle(Ink.ink)
                .padding(.top, 14)
            Text("a quiet pomodoro timer")
                .font(Ink.text(15))
                .foregroundStyle(Ink.faint)
                .padding(.top, 4)

            AccountForm(preview: preview, creating: true, titled: false, cancel: nil, done: {})
                .frame(width: 400)
                .padding(.top, 36)

            Button("continue offline") { sync.welcomed = true }
                .buttonStyle(.inkLink(selected: false, size: 15))
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
    }
}
