import AppKit
import Foundation
import Observation
import TetodoroCore

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "match system"
        case .light: "teto"
        case .dark: "ink"
        }
    }
}

/// The app's single source of truth: owns the engine, drives its clock,
/// writes finished focus blocks to the store, and keeps the heatmap fresh.
/// Views read from it and call its intents; nothing else touches the store.
@Observable @MainActor
final class AppModel {
    private(set) var engine: PomodoroEngine
    /// Wall clock as of the last tick; views derive countdowns from it.
    private(set) var now = Date()
    private(set) var heatmap = Heatmap.empty
    private(set) var recentTags: [String] = []
    private(set) var lastError: String?

    /// What you're studying. Captured when a focus block starts.
    var tag: String {
        didSet { defaults.set(tag, forKey: Keys.tag) }
    }

    /// Nil shows every session.
    var tagFilter: String? {
        didSet { rebuildHeatmap() }
    }

    var config: TimerConfig {
        get { engine.config }
        set {
            engine.config = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.config)
            }
        }
    }

    var soundOn: Bool {
        didSet { defaults.set(soundOn, forKey: Keys.sound) }
    }

    var theme: Theme {
        didSet {
            defaults.set(theme.rawValue, forKey: Keys.theme)
            applyTheme()
        }
    }

    private let store: SessionStore
    private let sync: SyncService
    private let defaults: UserDefaults
    private let deviceID: String
    private let notifier = Notifier()
    private let builder = HeatmapBuilder()
    private var tickTask: Task<Void, Never>?
    private var blockTag: String?
    private var yearSessions: [FocusSession] = []

    init(store: SessionStore, sync: SyncService = DisabledSync(), defaults: UserDefaults = .standard,
         configOverride: TimerConfig? = nil) {
        self.store = store
        self.sync = sync
        self.defaults = defaults
        self.deviceID = DeviceIdentity.current(defaults)

        let saved = defaults.data(forKey: Keys.config)
            .flatMap { try? JSONDecoder().decode(TimerConfig.self, from: $0) }
        self.engine = PomodoroEngine(config: configOverride ?? saved ?? .standard)
        self.tag = defaults.string(forKey: Keys.tag) ?? ""
        self.soundOn = defaults.object(forKey: Keys.sound) as? Bool ?? true
        self.theme = defaults.string(forKey: Keys.theme).flatMap(Theme.init) ?? .system

        reload()
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Production wiring. `TETODORO_DB` points at another database file,
    /// `TETODORO_FAST=1` shrinks minutes to seconds, and `TETODORO_THEME`
    /// (system|light|dark) overrides the saved theme — all for trying things out.
    static func live() -> AppModel {
        let env = ProcessInfo.processInfo.environment
        let url = env["TETODORO_DB"].map { URL(filePath: $0) } ?? SQLiteSessionStore.defaultURL
        let store: SessionStore
        do {
            store = try SQLiteSessionStore(url: url)
        } catch {
            // Keep the timer usable even if the disk isn't; nothing is kept.
            store = try! SQLiteSessionStore.inMemory()
        }
        let fast = env["TETODORO_FAST"] == "1"
            ? TimerConfig(focus: 20, shortBreak: 5, longBreak: 10) : nil
        let model = AppModel(store: store, configOverride: fast)
        if let theme = env["TETODORO_THEME"].flatMap(Theme.init) { model.theme = theme }
        return model
    }

    // MARK: Derived

    var remaining: TimeInterval { engine.remaining(at: now) }
    var progress: Double { engine.progress(at: now) }
    var phase: Phase { engine.phase }
    var isRunning: Bool { engine.isRunning }
    var isActive: Bool { !engine.isIdle }

    // MARK: Intents

    func toggle() {
        let starting = engine.isIdle
        now = Date()
        engine.toggle(at: now)
        if starting {
            notifier.prepare()
            if engine.phase == .focus { captureTag() }
        }
        syncTicking()
    }

    func skip() {
        now = Date()
        handle(engine.skip(at: now))
        syncTicking()
    }

    func reset() {
        now = Date()
        if let record = engine.reset(at: now) { log(record) }
        syncTicking()
    }

    /// Themes are appearances: the Ink palette resolves per appearance, so
    /// pinning NSApp's appearance re-themes every window at once.
    func applyTheme() {
        NSApp?.appearance = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Clock

    private func syncTicking() {
        if engine.isRunning {
            guard tickTask == nil else { return }
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.tick()
                }
            }
        } else {
            tickTask?.cancel()
            tickTask = nil
        }
    }

    private func tick() {
        now = Date()
        if let transition = engine.tick(at: now) {
            handle(transition)
            syncTicking()
        }
    }

    private func handle(_ t: Transition) {
        if let record = t.record { log(record) }
        if t.next == .focus && engine.isRunning { captureTag() }
        guard t.natural else { return }

        let copy = Copy.finished(t.finished, next: t.next, minutes: Int(config.focus / 60))
        notifier.post(title: copy.title, body: copy.body)
        if soundOn { NSSound(named: t.finished == .focus ? "Glass" : "Tink")?.play() }
    }

    // MARK: Data

    private func captureTag() {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        blockTag = trimmed.isEmpty ? nil : trimmed
    }

    private func log(_ r: FocusRecord) {
        let session = FocusSession(
            startedAt: r.startedAt, endedAt: r.endedAt, focusSeconds: r.focusSeconds,
            plannedSeconds: r.plannedSeconds, completed: r.completed, tag: blockTag,
            deviceID: deviceID, updatedAt: Date())
        do {
            try store.save(session)
            lastError = nil
        } catch {
            lastError = "couldn't save that session."
        }
        reload()
    }

    func reload() {
        let range = builder.range(today: Date())
        yearSessions = (try? store.sessions(from: range.from, to: range.to)) ?? []
        recentTags = (try? store.tags(limit: 6)) ?? []
        if let filter = tagFilter, !recentTags.contains(filter) { tagFilter = nil }
        rebuildHeatmap()
    }

    private func rebuildHeatmap() {
        let shown = tagFilter.map { t in yearSessions.filter { $0.tag == t } } ?? yearSessions
        heatmap = builder.build(shown, today: Date())
    }

    private enum Keys {
        static let config = "tetodoro.config"
        static let tag = "tetodoro.tag"
        static let sound = "tetodoro.sound"
        static let theme = "tetodoro.theme"
    }
}
