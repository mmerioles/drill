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
    @State private var pageHeight: CGFloat = 0
    @State private var stackHeight: CGFloat = 0

    /// The window is sized to the stack: header, 24, the stack, 32.
    static let windowSize = CGSize(width: 780, height: Page.header + Page.underHeader + Page.stack + Page.bottom)

    enum Page {
        /// 24 of padding over 24 of links.
        static let header: CGFloat = 48
        static let underHeader: CGFloat = 24
        static let bottom: CGFloat = 32
        /// Timer block (ring, tag, controls), 56, year block (filter, grid, stats).
        static let stack: CGFloat = 683
        static let gutter: CGFloat = 40
        /// Of a taller window's free space, 2 parts go above the stack and 3 below.
        static let aboveShare: CGFloat = 0.4
        static let maxAbove: CGFloat = 160
    }

    /// Free room beyond the window the stack was sized for, split 2 : 3.
    private var above: CGFloat {
        guard stackHeight > 0 else { return Page.underHeader }
        let free = max(0, pageHeight - Page.header - Page.underHeader - stackHeight - Page.bottom)
        return Page.underHeader + min(Page.maxAbove, free * Page.aboveShare)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Spacer()
                if let error = model.lastError {
                    Text(error).font(Ink.text(13)).foregroundStyle(Ink.faint)
                }
                HStack(spacing: 20) {
                    // Offered between blocks only: updating relaunches the app.
                    if updater.state == .installing {
                        Text("updating…").font(Ink.text(15)).foregroundStyle(Ink.faint)
                    } else if let release = updater.available, !model.isActive {
                        Button("update to \(release.version.description)") { Task { await updater.install() } }
                    }
                    if sync.showsLink {
                        Button(sync.state == .offline ? "offline" : "sync", action: sync.syncNow)
                    }
                    Button("inspo") { openWindow(id: "inspo") }
                    SettingsLink { Text("settings") }
                }
                .buttonStyle(.inkLink(selected: false, size: 15))
            }
            .frame(height: Page.header - Page.underHeader)
            .padding(.top, Page.underHeader)

            VStack(spacing: 0) {
                TimerView()
                HeatmapSection(openToday: openToday)
                    .padding(.top, 56)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { stackHeight = $0 }
            .padding(.top, above)

            Spacer(minLength: Page.bottom)
        }
        .padding(.horizontal, Page.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { pageHeight = $0 }
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
