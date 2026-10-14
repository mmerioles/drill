import AppKit
import DrillCore
import InkKit
import SwiftUI

/// `Drill --render <folder>`: the main window's face in each mode and state,
/// light and dark, drawn to PNGs at 2× without opening a window, on a
/// made-up year in memory. For looking at changes; nothing here is kept.
/// (The tag field is an AppKit control, which offscreen rendering draws as
/// a placeholder box.)
@MainActor
enum Render {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return }
        let folder = URL(filePath: args[i + 1], directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var failed = 0
        for theme in Theme.allCases {
            for (name, mode, state) in shots {
                let model = demo(theme: theme)
                if model.mode != mode { model.switchMode() }
                state(model)
                let view = MainView()
                    .environment(model)
                    .environment(Updater())
                    .environment(Sync(store: model.store, deviceID: model.deviceID,
                                      defaults: UserDefaults(suiteName: "drill.render")!, onPulled: {}))
                    .frame(width: 780, height: 700)
                    .environment(\.colorScheme, theme == .light ? .light : .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let file = folder.appending(path: "\(name)-\(theme.rawValue).png")
                // The palette resolves per appearance, and the renderer draws
                // in whatever appearance is current, not NSApp's.
                var image: NSImage?
                NSAppearance(named: theme == .light ? .aqua : .darkAqua)!
                    .performAsCurrentDrawingAppearance { image = renderer.nsImage }
                if let image, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: file)
                    print("rendered \(file.lastPathComponent)")
                } else {
                    failed += 1
                    print("couldn't render \(file.lastPathComponent)")
                }
            }
        }
        // The marks, large, to judge their drawing.
        let marks = HStack(spacing: 40) {
            ForEach([Glyph.Kind.tomato, .stopwatch, .drill], id: \.self) { kind in
                VStack(spacing: 24) {
                    Glyph(kind, size: 120, boiling: false, lineWidth: 6, roughness: 0.6)
                    Glyph(kind, size: 18, boiling: false, lineWidth: 1.5)
                }
            }
        }
        .padding(40)
        .background(Color(white: 0.95))
        let renderer = ImageRenderer(content: marks)
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appending(path: "marks.png"))
        }
        exit(failed == 0 ? 0 : 1)
    }

    private static let shots: [(String, TimerMode, (AppModel) -> Void)] = [
        ("pomodoro-idle", .pomodoro, { _ in }),
        ("pomodoro-running", .pomodoro, { m in m.tag = "15-213"; m.toggle(); m.freeze(at: Date() + 863) }),
        ("stopwatch-idle", .stopwatch, { _ in }),
        ("stopwatch-running", .stopwatch, { m in m.tag = "piano"; m.toggle(); m.freeze(at: Date() + 2537) }),
    ]

    /// A model on an in-memory store with a few months of sessions, and
    /// throwaway settings so nothing touches your real ones.
    private static func demo(theme: Theme) -> AppModel {
        let defaults = UserDefaults(suiteName: "drill.render")!
        defaults.removePersistentDomain(forName: "drill.render")
        let store = try! SQLiteSessionStore.inMemory()
        var rng = SystemRandomNumberGenerator()
        let tags = ["15-213", "jp", "piano"]
        for back in 0..<200 where back < 13 || Int.random(in: 0..<10, using: &rng) < 6 {
            let day = Calendar.current.date(byAdding: .day, value: -back, to: Date())!
            for b in 0..<Int.random(in: 1...4, using: &rng) {
                let start = Calendar.current.date(bySettingHour: 9 + b * 2, minute: 0, second: 0, of: day)!
                try? store.save(FocusSession(startedAt: start, endedAt: start + 1500, focusSeconds: 1500,
                                             plannedSeconds: 1500, completed: true, tag: tags.randomElement(),
                                             deviceID: "render", updatedAt: start))
            }
        }
        let model = AppModel(store: store, defaults: defaults)
        model.theme = theme
        NSApp.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        return model
    }
}
