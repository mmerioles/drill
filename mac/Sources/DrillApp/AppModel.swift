import AppKit
import Foundation
import Observation
import DrillCore

/// light is the teto palette, dark is pure ink. See Ink.swift.
enum Theme: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
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
            // The banner names the next phase and its length: keep it true.
            if engine.isRunning { scheduleBanner() }
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

    let store: SessionStore
    let deviceID: String
    /// Called after a finished block is written, so sync can send it along.
    var onLogged: (() -> Void)?
    private let defaults: UserDefaults
    private let notifier = Notifier()
    private let builder = HeatmapBuilder()
    private var tickTask: Task<Void, Never>?
    private var blockTag: String?
    private var yearSessions: [FocusSession] = []

    init(store: SessionStore, defaults: UserDefaults = .standard, configOverride: TimerConfig? = nil) {
        self.store = store
        self.defaults = defaults
        self.deviceID = DeviceIdentity.current(defaults)

        let saved = defaults.data(forKey: Keys.config)
            .flatMap { try? JSONDecoder().decode(TimerConfig.self, from: $0) }
        self.engine = PomodoroEngine(config: configOverride ?? saved ?? .standard)
        self.tag = defaults.string(forKey: Keys.tag) ?? ""
        self.soundOn = defaults.object(forKey: Keys.sound) as? Bool ?? true
        self.theme = defaults.string(forKey: Keys.theme).flatMap(Theme.init) ?? .dark

        reload()
        notifier.onStart = { [weak self] in self?.startNext() }

        // A new day, time zone or clock, or a wake from sleep: "today", the
        // week and the streak may have moved, and the countdown should catch up.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.timeMoved() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.timeMoved() }
        }
        // Quitting mid-focus logs the focus so far, like reset.
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isActive == true { self?.reset() } }
        }
    }

    /// Production wiring. `DRILL_DB` points at another database file,
    /// `DRILL_FAST=1` shrinks minutes to seconds, and `DRILL_THEME`
    /// (light|dark) overrides the saved theme — all for trying things out.
    static func live() -> AppModel {
        let env = ProcessInfo.processInfo.environment
        let url = env["DRILL_DB"].map { URL(filePath: $0) } ?? SQLiteSessionStore.defaultURL
        let store: SessionStore
        do {
            store = try SQLiteSessionStore(url: url)
        } catch {
            // Keep the timer usable even if the disk isn't; nothing is kept.
            store = try! SQLiteSessionStore.inMemory()
        }
        let fast = env["DRILL_FAST"] == "1"
            ? TimerConfig(focus: 20, shortBreak: 5, longBreak: 10) : nil
        let model = AppModel(store: store, configOverride: fast)
        if let theme = env["DRILL_THEME"].flatMap(Theme.init) { model.theme = theme }
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
        if engine.isRunning { scheduleBanner() } else { notifier.cancel() }
        syncTicking()
    }

    func skip() {
        now = Date()
        notifier.cancel()
        handle(engine.skip(at: now))
        syncTicking()
    }

    func reset() {
        now = Date()
        notifier.cancel()
        if let record = engine.reset(at: now) { log(record) }
        syncTicking()
    }

    /// The banner's "start break" / "start focus": starts the waiting phase,
    /// unless you've already started it yourself.
    private func startNext() {
        if engine.isIdle { toggle() }
    }

    /// Themes are appearances: the Ink palette resolves per appearance, so
    /// pinning NSApp's appearance re-themes every window at once.
    func applyTheme() {
        NSApp?.appearance = switch theme {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Clock

    /// Wakes once per shown second, just past the boundary, so everything
    /// watching `now` redraws once a second; nothing wakes while not running.
    /// Restarted on every start, pause and phase change to stay aligned.
    private func syncTicking() {
        tickTask?.cancel()
        tickTask = nil
        guard engine.isRunning else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled, let wait = self?.engine.untilNextSecond(at: Date()) {
                try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(20))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func tick() {
        now = Date()
        // Only touch the observed engine when the phase is really over:
        // a no-op mutation would still redraw everything that reads it.
        guard case .running(let endsAt) = engine.status, now >= endsAt,
              let transition = engine.tick(at: now) else { return }
        handle(transition)
        syncTicking()
    }

    /// The clock jumped (wake, time zone, clock change) or a day began.
    private func timeMoved() {
        reload()
        now = Date()
        if engine.isRunning { tick(); syncTicking() }
    }

    private func handle(_ t: Transition) {
        if let record = t.record { log(record) }
        if t.next == .focus && engine.isRunning { captureTag() }
        guard t.natural else { return }

        // The banner itself was scheduled for this moment; an auto-started
        // phase gets its own.
        if engine.isRunning { scheduleBanner() }
        if soundOn { NSSound(named: t.finished == .focus ? "Glass" : "Tink")?.play() }
    }

    /// Schedules the banner for the running phase's end.
    private func scheduleBanner() {
        guard case .running(let endsAt) = engine.status else { return }
        let next = engine.upcoming
        let copy = Copy.finished(engine.phase, next: config.duration(of: next.phase))
        notifier.schedule(title: copy.title, body: copy.body, breakEnding: engine.phase.isBreak,
                          at: endsAt, offering: next.autoStarts ? nil : next.phase)
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
            onLogged?()
        } catch {
            lastError = "couldn't save that session."
        }
        reload()
    }

    func reload() {
        let range = builder.range(today: Date())
        yearSessions = (try? store.sessions(from: range.from, to: range.to)) ?? []
        recentTags = (try? store.tags(limit: 6)) ?? []
        // Clearing the filter rebuilds through its didSet; don't build twice.
        if let filter = tagFilter, !recentTags.contains(filter) { tagFilter = nil } else { rebuildHeatmap() }
    }

    private func rebuildHeatmap() {
        let shown = tagFilter.map { t in yearSessions.filter { $0.tag == t } } ?? yearSessions
        let built = builder.build(shown, today: Date())
        if built != heatmap { heatmap = built }
    }

    private enum Keys {
        static let config = "drill.config"
        static let tag = "drill.tag"
        static let sound = "drill.sound"
        static let theme = "drill.theme"
    }
}
