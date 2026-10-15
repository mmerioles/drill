import AppKit
import DrillCore
import InkKit
import SwiftUI

/// `Drill --render <folder>`: draws the main window, a day's popover, the
/// account sheet and the marks to PNGs at 2×, light and dark, from a made-up
/// year in memory.
/// (Offscreen rendering draws the AppKit tag field as a placeholder box.)
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
            for (name, mode, state, query) in shots {
                let model = demo(theme: theme)
                model.switchMode(to: mode)
                state(model)
                let view = MainView(palettePreview: query)
                    .environment(model)
                    .environment(Updater())
                    .environment(Sync(store: model.store, deviceID: model.deviceID,
                                      defaults: UserDefaults(suiteName: "drill.render")!, onPulled: {}))
                    .frame(width: 780, height: 700)
                if !write(view, theme: theme, to: folder.appending(path: "\(name)-\(theme.rawValue).png")) {
                    failed += 1
                }
            }
        }
        // The popover opens in its own window, which offscreen rendering can't reach.
        for (theme, preview) in [(Theme.light, DayDetail.Preview.none), (.dark, .none),
                                 (.light, .editingFirst), (.dark, .adding), (.light, .removedFirst)] {
            let model = demo(theme: theme)
            let view = DayDetail(day: Date(), sessions: model.sessions(on: Date()), preview: preview)
                .environment(model)
            write(view, theme: theme, to: folder.appending(path: "day-\(preview)-\(theme.rawValue).png"))
        }

        for (theme, preview) in [(Theme.light, AccountSheet.Preview.available), (.dark, .available),
                                 (.light, .taken), (.dark, .taken)] {
            let model = demo(theme: theme)
            let view = AccountSheet(preview: preview)
                .environment(Sync(store: model.store, deviceID: model.deviceID,
                                  defaults: UserDefaults(suiteName: "drill.render")!, onPulled: {}))
            write(view, theme: theme, to: folder.appending(path: "account-\(preview)-\(theme.rawValue).png"))
        }

        let marks = HStack(spacing: 40) {
            ForEach([Glyph.Kind.tomato, .stopwatch, .runner, .sneaker, .drill], id: \.self) { kind in
                VStack(spacing: 24) {
                    Glyph(kind, size: 120, boiling: false, lineWidth: 6, roughness: 0.6)
                    Glyph(kind, size: 18, boiling: false, lineWidth: 1.5)
                }
            }
        }
        .padding(40)
        .background(Color(white: 0.95))
        write(marks, theme: .light, to: folder.appending(path: "marks.png"))
        exit(failed == 0 ? 0 : 1)
    }

    @discardableResult
    private static func write(_ view: some View, theme: Theme, to file: URL) -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, theme == .light ? .light : .dark))
        renderer.scale = 2
        // The palette resolves per appearance, and the renderer draws in the
        // current drawing appearance, not NSApp's.
        var image: NSImage?
        NSAppearance(named: theme == .light ? .aqua : .darkAqua)!
            .performAsCurrentDrawingAppearance { image = renderer.nsImage }
        guard let tiff = image?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              (try? png.write(to: file)) != nil
        else {
            print("couldn't render \(file.lastPathComponent)")
            return false
        }
        print("rendered \(file.lastPathComponent)")
        return true
    }

    private static let shots: [(String, TimerMode, (AppModel) -> Void, String?)] = [
        ("pomodoro-idle", .pomodoro, { _ in }, nil),
        ("pomodoro-running", .pomodoro, { m in m.tag = "15-213"; m.toggle(); m.freeze(at: Date() + 863) }, nil),
        ("stopwatch-idle", .stopwatch, { _ in }, nil),
        ("stopwatch-running", .stopwatch, { m in m.tag = "piano"; m.toggle(); m.freeze(at: Date() + 2537) }, nil),
        ("intervals-idle", .intervals, { _ in }, nil),
        // 300/60 intervals: 743s in is the third run, 1040s the third walk.
        ("intervals-running", .intervals, { m in m.toggle(); m.freeze(at: Date() + 743) }, nil),
        ("intervals-walk", .intervals, { m in m.toggle(); m.freeze(at: Date() + 1040) }, nil),
        ("goal-met", .pomodoro, { m in m.dailyGoal = 30 * 60 }, nil),
        ("palette", .pomodoro, { _ in }, "st"),
    ]

    /// An in-memory store with a few months of sessions, and throwaway defaults.
    private static func demo(theme: Theme) -> AppModel {
        let defaults = UserDefaults(suiteName: "drill.render")!
        defaults.removePersistentDomain(forName: "drill.render")
        let store = try! SQLiteSessionStore.inMemory()
        var rng = SystemRandomNumberGenerator()
        let tags = ["15-213", "jp", "piano"]
        for back in 1..<200 where back < 13 || Int.random(in: 0..<10, using: &rng) < 6 {
            let day = Calendar.current.date(byAdding: .day, value: -back, to: Date())!
            for b in 0..<Int.random(in: 1...4, using: &rng) {
                let start = Calendar.current.date(bySettingHour: 9 + b * 2, minute: 0, second: 0, of: day)!
                try? store.save(FocusSession(startedAt: start, endedAt: start + 1500, focusSeconds: 1500,
                                             plannedSeconds: 1500, completed: true, tag: tags.randomElement(),
                                             deviceID: "render", updatedAt: start))
            }
        }
        // Today: two pomodoros and one stopwatch block.
        let morning = Calendar.current.date(bySettingHour: 9, minute: 5, second: 0, of: Date())!
        for (offset, length, planned, tag) in [(0.0, 1500.0, 1500.0, "15-213"), (1800, 1500, 1500, "15-213"),
                                               (5400, 2720, 0, "piano")] {
            let start = morning + offset
            try? store.save(FocusSession(startedAt: start, endedAt: start + length, focusSeconds: length,
                                         plannedSeconds: planned, completed: true, tag: tag,
                                         deviceID: "render", updatedAt: start))
        }
        let model = AppModel(store: store, defaults: defaults)
        model.theme = theme
        NSApp.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        return model
    }
}
