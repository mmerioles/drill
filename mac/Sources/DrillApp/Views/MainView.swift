import InkKit
import SwiftUI

struct MainView: View {
    /// For --render: shows the palette with this query typed.
    var palettePreview: String?
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(Sync.self) private var sync
    /// The page holds focus so the tag field doesn't grab it and space toggles the timer.
    @FocusState private var pageFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paletteShown = false
    @State private var openToday = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Spacer()
                if let error = model.lastError {
                    Text(error).font(Ink.text(13)).foregroundStyle(Ink.faint)
                }
                HStack(spacing: 16) {
                    // Offered between blocks only: updating relaunches the app.
                    if updater.state == .installing {
                        Text("updating…").font(Ink.text(14)).foregroundStyle(Ink.faint)
                    } else if let release = updater.available, !model.isActive {
                        Button("update to \(release.version.description)") { Task { await updater.install() } }
                    }
                    if sync.showsLink {
                        Button(sync.state == .offline ? "offline" : "sync", action: sync.syncNow)
                    }
                    Button("inspo") { openWindow(id: "inspo") }
                    SettingsLink { Text("settings") }
                }
                .buttonStyle(.inkLink)
            }
            .padding(.top, 8)

            Spacer(minLength: 20)
            TimerView()
            Spacer(minLength: 32)

            HeatmapSection(openToday: openToday)
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
        .overlay { palette }
        .environment(\.paletteOpen, paletteShown)
        .focusedSceneValue(\.palette, $paletteShown)
        .onChange(of: paletteShown) { if !paletteShown { pageFocused = true } }
        .onAppear {
            model.applyTheme()
            model.reload()
        }
    }

    /// Floats a fifth of the way down, over a faint veil that closes it.
    private var palette: some View {
        GeometryReader { geo in
            if paletteShown || palettePreview != nil {
                ZStack(alignment: .top) {
                    Ink.paper.opacity(0.35)
                        .onTapGesture { paletteShown = false }
                    PaletteView(preview: palettePreview, close: { paletteShown = false },
                                openToday: { openToday += 1 })
                        .frame(width: min(520, geo.size.width - 32))
                        .padding(.top, geo.size.height * 0.2)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : -6)),
                                                removal: .opacity))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: paletteShown ? 0.12 : 0.08), value: paletteShown)
    }
}
