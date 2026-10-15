import InkKit
import SwiftUI

/// Whenever nobody is signed in: sign in, or make an account. Takes the
/// timer's place in the main window.
struct WelcomeView: View {
    var preview: AccountForm.Preview = .none

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

            AccountForm(preview: preview, titled: false, cancel: nil, done: {})
                .frame(width: 400)
                .padding(.top, 36)
        }
        .frame(maxWidth: .infinity)
    }
}
