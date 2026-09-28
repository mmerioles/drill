import InkKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    /// The page itself holds focus by default, so the tag field doesn't grab
    /// it on open, and space can start and pause the timer.
    @FocusState private var pageFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Glyph(.drill, size: 22, boiling: model.isRunning, lineWidth: 1.8, tint: Ink.accent)
                Text("tetodoro")
                    .font(Ink.word(20))
                    .foregroundStyle(Ink.ink)
                Spacer()
                if let error = model.lastError {
                    Text(error).font(Ink.text(13)).foregroundStyle(Ink.faint)
                }
                HStack(spacing: 16) {
                    Button("inspo") { openWindow(id: "inspo") }
                    SettingsLink { Text("settings") }
                }
                .buttonStyle(.inkLink)
            }
            .padding(.top, 8)

            Spacer(minLength: 20)
            TimerView()
            Spacer(minLength: 32)

            HeatmapSection()
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 32)
        .padding(.top, 20)
        .background(Ink.paper)
        .focusable()
        .focusEffectDisabled()
        .focused($pageFocused)
        .defaultFocus($pageFocused, true)
        .onKeyPress(.space) {
            model.toggle()
            return .handled
        }
        // Clicking empty paper ends tag editing.
        .onTapGesture { pageFocused = true }
        .onAppear {
            model.applyTheme()
            model.reload()
        }
    }
}
