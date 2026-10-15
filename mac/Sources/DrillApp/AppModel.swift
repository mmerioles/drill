import AppKit
import Foundation
import Observation
import DrillCore
import InkKit

enum Theme: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
}

enum TimerMode: String, CaseIterable {
    case pomodoro, stopwatch, intervals

    /// What ⌘T switches to.
    var next: TimerMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// The app's single source of truth: owns the timers and their clock, writes
/// finished blocks to the store, and keeps the heatmap fresh.
@Observable @MainActor
final class AppModel {
    private(set) var engine: PomodoroEngine
    private(set) var stopwatch = Stopwatch()
    private(set) var intervals: IntervalEngine
    /// Which timer the face shows. Switches only between blocks.
    private(set) var mode: TimerMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }
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

    var intervalConfig: IntervalConfig {
        get { intervals.config }
        set {
            intervals.config = newValue
            if intervals.isRunning { scheduleIntervalBanner() }
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.intervals)
            }
        }
    }

    var soundOn: Bool {
        didSet { defaults.set(soundOn, forKey: Keys.sound) }
    }

    /// Focus time to aim for each day, in seconds; 0 is off.
    var dailyGoal: TimeInterval {
        didSet { defaults.set(dailyGoal, forKey: Keys.goal) }
    }

    /// Today's focus across all tags, ignoring the filter: what the goal counts.
    private(set) var todayTotal: TimeInterval = 0

    var theme: Theme {
        didSet {
            defaults.set(theme.rawValue, forKey: Keys.theme)
            applyTheme()
        }
    }

    /// Swapped by sign-in and sign-out (`use`).
    private(set) var store: SessionStore
    let deviceID: String
    /// Called after any write, so sync can send it along.
    var onLogged: (() -> Void)?
    private let defaults: UserDefaults
    private let notifier = Notifier()
    private let builder = HeatmapBuilder(calendar: .autoupdatingCurrent)
    private var tickTask: Task<Void, Never>?
    private var blockTag: String?
    private var yearSessions: [FocusSession] = []

    init(store: SessionStore, defaults: UserDefaults = .standard, configOverride: TimerConfig? = nil,
         intervalsOverride: IntervalConfig? = nil) {
        self.store = store
        self.defaults = defaults
        self.deviceID = DeviceIdentity.current(defaults)

        let saved = defaults.data(forKey: Keys.config)
            .flatMap { try? JSONDecoder().decode(TimerConfig.self, from: $0) }
        self.engine = PomodoroEngine(config: configOverride ?? saved ?? .standard)
        let savedIntervals = defaults.data(forKey: Keys.intervals)
            .flatMap { try? JSONDecoder().decode(IntervalConfig.self, from: $0) }
        self.intervals = IntervalEngine(config: intervalsOverride ?? savedIntervals ?? .standard)
        self.tag = defaults.string(forKey: Keys.tag) ?? ""
        self.soundOn = defaults.object(forKey: Keys.sound) as? Bool ?? true
        self.dailyGoal = defaults.object(forKey: Keys.goal) as? Double ?? 2 * 3600
        self.theme = defaults.string(forKey: Keys.theme).flatMap(Theme.init) ?? .dark
        self.mode = defaults.string(forKey: Keys.mode).flatMap(TimerMode.init) ?? .pomodoro

        reload()
        notifier.onStart = { [weak self] offered in self?.startNext(offered) }

        // A new day, time zone, clock change or wake: "today" may have moved.
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

    /// Env for trying things out: `DRILL_DB` (the offline database file;
    /// account ones go beside it), `DRILL_FAST=1` (minutes become seconds),
    /// `DRILL_THEME` (light|dark).
    static var stores: AccountStores {
        let env = ProcessInfo.processInfo.environment
        return AccountStores(offlineURL: env["DRILL_DB"].map { URL(filePath: $0) } ?? SQLiteSessionStore.defaultURL)
    }

    static func live(store: SessionStore) -> AppModel {
        let env = ProcessInfo.processInfo.environment
        let fast = env["DRILL_FAST"] == "1"
        let model = AppModel(
            store: store,
            configOverride: fast ? TimerConfig(focus: 20, shortBreak: 5, longBreak: 10) : nil,
            intervalsOverride: fast ? IntervalConfig(run: 15, walk: 5) : nil)
        if let theme = env["DRILL_THEME"].flatMap(Theme.init) { model.theme = theme }
        return model
    }

    // MARK: Derived

    var isStopwatch: Bool { mode == .stopwatch }
    var isIntervals: Bool { mode == .intervals }
    /// Time left on the pomodoro or interval, or counted on the stopwatch.
    var shown: TimeInterval {
        switch mode {
        case .pomodoro: engine.remaining(at: now)
        case .stopwatch: stopwatch.elapsed(at: now)
        case .intervals: intervals.remaining(at: now)
        }
    }
    /// The stopwatch's ring sweeps once an hour.
    var progress: Double {
        switch mode {
        case .pomodoro: engine.progress(at: now)
        case .stopwatch: stopwatch.elapsed(at: now).truncatingRemainder(dividingBy: 3600) / 3600
        case .intervals: intervals.progress(at: now)
        }
    }
    var clock: String { Copy.clock(shown, countingUp: isStopwatch) }
    /// The whole second shown, for animating only when it changes.
    var shownSecond: Int { Int(isStopwatch ? (shown + 1e-6).rounded(.down) : shown.rounded(.up)) }
    /// The word above the digits. The stopwatch only ever says "paused".
    var status: String? {
        switch mode {
        case .pomodoro: Copy.status(engine.phase, running: isRunning, active: isActive)
        case .stopwatch: isActive && !isRunning ? "paused" : nil
        case .intervals: isActive ? Copy.status(Copy.phaseName(intervals.phase), running: isRunning) : nil
        }
    }
    var phase: Phase { engine.phase }
    /// The mark under the digits: which timer, and for intervals, which leg.
    var mark: Glyph.Kind {
        switch mode {
        case .pomodoro: .tomato
        case .stopwatch: .stopwatch
        case .intervals: intervals.phase == .walk ? .sneaker : .runner
        }
    }
    /// "round 3 · 18m" while a workout is on.
    var roundLine: String? {
        isIntervals && isActive ? Copy.round(intervals.round, elapsed: intervals.elapsed(at: now)) : nil
    }
    var isRunning: Bool {
        switch mode {
        case .pomodoro: engine.isRunning
        case .stopwatch: stopwatch.isRunning
        case .intervals: intervals.isRunning
        }
    }
    var isActive: Bool {
        switch mode {
        case .pomodoro: !engine.isIdle
        case .stopwatch: !stopwatch.isIdle
        case .intervals: !intervals.isIdle
        }
    }

    // MARK: Intents

    func toggle() {
        if isStopwatch {
            now = Date()
            if stopwatch.isIdle { captureTag() }
            stopwatch.toggle(at: now)
            syncTicking()
            return
        }
        if isIntervals {
            now = Date()
            if intervals.isIdle { notifier.prepare() }
            intervals.toggle(at: now)
            if intervals.isRunning { scheduleIntervalBanner() } else { notifier.cancel() }
            syncTicking()
            return
        }
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
        guard !isStopwatch else { return }
        now = Date()
        notifier.cancel()
        if isIntervals {
            guard let t = intervals.skip(at: now) else { return }
            // The banner for this transition was pending; a skip announces itself.
            announce(t, at: now)
            handle(t)
        } else {
            handle(engine.skip(at: now))
        }
        syncTicking()
    }

    /// Reset for the pomodoro and stopwatch; "done" for intervals, which
    /// logs the workout.
    func reset() {
        now = Date()
        switch mode {
        case .stopwatch:
            if let record = stopwatch.reset(at: now) { log(record) }
        case .intervals:
            notifier.cancel()
            if let record = intervals.stop(at: now) { log(record) }
        case .pomodoro:
            notifier.cancel()
            if let record = engine.reset(at: now) { log(record) }
        }
        syncTicking()
    }

    /// For --render: shows the face as of `date`, with no clock running.
    func freeze(at date: Date) {
        tickTask?.cancel()
        tickTask = nil
        now = date
        _ = intervals.tick(at: date)
    }

    /// Only between blocks, so switching never drops time.
    func switchMode() {
        switchMode(to: mode.next)
    }

    func switchMode(to new: TimerMode) {
        guard !isActive, new != mode else { return }
        mode = new
        now = Date()
    }

    /// The banner's start button: starts the offered phase only if it's
    /// still waiting idle.
    private func startNext(_ offered: Phase) {
        if !isStopwatch && engine.isIdle && engine.phase == offered { toggle() }
    }

    /// The Ink palette resolves per appearance, so pinning NSApp's
    /// appearance re-themes every window.
    func applyTheme() {
        NSApp?.appearance = switch theme {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Clock

    /// Wakes just past each shown-second boundary while running, and not at
    /// all otherwise. Restarted on every start, pause and phase change.
    private func syncTicking() {
        tickTask?.cancel()
        tickTask = nil
        guard isRunning else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled, let wait = self?.untilNextSecond() {
                try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(20))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func untilNextSecond() -> TimeInterval? {
        switch mode {
        case .pomodoro: engine.untilNextSecond(at: Date())
        case .stopwatch: stopwatch.untilNextSecond(at: Date())
        case .intervals: intervals.untilNextSecond(at: Date())
        }
    }

    private func tick() {
        now = Date()
        // A no-op mutation of the observed engine would still redraw everything.
        switch mode {
        case .stopwatch:
            return
        case .intervals:
            guard case .running(let endsAt) = intervals.status, now >= endsAt,
                  let transition = intervals.tick(at: now) else { return }
            handle(transition)
        case .pomodoro:
            guard case .running(let endsAt) = engine.status, now >= endsAt,
                  let transition = engine.tick(at: now) else { return }
            handle(transition)
        }
        syncTicking()
    }

    private func timeMoved() {
        reload()
        now = Date()
        if isRunning { tick(); syncTicking() }
    }

    private func handle(_ t: Transition) {
        if let record = t.record { log(record) }
        if t.next == .focus && engine.isRunning { captureTag() }
        guard t.natural else { return }

        // This banner was already scheduled; an auto-started phase needs its own.
        if engine.isRunning { scheduleBanner() }
        chime(focusDone: t.finished == .focus)
    }

    /// Every interval change is cued, skipped or not.
    private func handle(_ t: IntervalTransition) {
        chime(focusDone: t.next == .run)
        if intervals.isRunning { scheduleIntervalBanner() }
    }

    private func chime(focusDone: Bool) {
        if soundOn { NSSound(named: focusDone ? "Glass" : "Tink")?.play() }
    }

    private func scheduleBanner() {
        guard case .running(let endsAt) = engine.status else { return }
        let next = engine.upcoming
        let copy = Copy.finished(engine.phase, next: config.duration(of: next.phase))
        notifier.schedule(title: copy.title, body: copy.body, breakEnding: engine.phase.isBreak,
                          at: endsAt, offering: next.autoStarts ? nil : next.phase)
    }

    /// The banner for the end of the current interval, ahead of time like
    /// the pomodoro's.
    private func scheduleIntervalBanner() {
        guard case .running(let endsAt) = intervals.status else { return }
        let next = intervals.upcoming
        announce(next.phase, round: next.round, at: endsAt)
    }

    private func announce(_ t: IntervalTransition, at when: Date) {
        announce(t.next, round: t.round, at: when)
    }

    private func announce(_ next: IntervalPhase, round: Int, at when: Date) {
        let copy = Copy.interval(next, round: round, length: intervalConfig.duration(of: next))
        // The run is the "focus" here: a walk ends like a break does.
        notifier.schedule(title: copy.title, body: copy.body, breakEnding: next == .run,
                          at: when, offering: nil)
    }

    // MARK: Data

    private func captureTag() {
        blockTag = Self.cleanTag(tag)
    }

    private func log(_ r: FocusRecord) {
        save(FocusSession(
            startedAt: r.startedAt, endedAt: r.endedAt, focusSeconds: r.focusSeconds,
            plannedSeconds: r.plannedSeconds, completed: r.completed, tag: blockTag,
            deviceID: deviceID, updatedAt: Date()),
             failure: "couldn't save that session.")
    }

    /// A workout is one completed session tagged "intervals".
    private func log(_ r: WorkoutRecord) {
        save(FocusSession(
            startedAt: r.startedAt, endedAt: r.endedAt, focusSeconds: r.seconds,
            plannedSeconds: r.seconds, completed: true, tag: Copy.intervalsTag,
            deviceID: deviceID, updatedAt: Date()),
             failure: "couldn't save that workout.")
    }

    private func save(_ session: FocusSession, failure: String) {
        do {
            try store.save(session)
            lastError = nil
            onLogged?()
        } catch {
            lastError = failure
        }
        reload()
    }

    /// Another account's sessions, or the offline ones.
    func use(_ new: SessionStore) {
        store = new
        reload()
    }

    func reload() {
        let range = builder.range(today: Date())
        yearSessions = (try? store.sessions(from: range.from, to: range.to)) ?? []
        todayTotal = builder.dailyTotals(yearSessions)[builder.calendar.startOfDay(for: Date())] ?? 0
        recentTags = (try? store.tags(limit: 6)) ?? []
        // Clearing the filter rebuilds through its didSet; don't build twice.
        if let filter = tagFilter, !recentTags.contains(filter) { tagFilter = nil } else { rebuildHeatmap() }
    }

    // MARK: Editing history

    /// Saves a change at least a whole second newer than the old copy (servers
    /// keep whole seconds; another device's clock may run ahead), so it wins
    /// the sync merge.
    @discardableResult
    private func rewrite(_ session: FocusSession) -> FocusSession {
        var s = session
        s.updatedAt = max(Date(), session.updatedAt.addingTimeInterval(1))
        save(s, failure: "couldn't save that change.")
        return s
    }

    /// Returns the tombstone, which `restore` takes back.
    @discardableResult
    func delete(_ session: FocusSession) -> FocusSession {
        var s = session
        s.deletedAt = Date()
        return rewrite(s)
    }

    func restore(_ tombstone: FocusSession) {
        var s = tombstone
        s.deletedAt = nil
        rewrite(s)
    }

    func update(_ session: FocusSession, start: Date, length: TimeInterval, tag: String?) {
        var s = session
        s.startedAt = start
        s.endedAt = start + length
        s.focusSeconds = length
        s.tag = Self.cleanTag(tag)
        rewrite(s)
    }

    /// A block you didn't time. No plan, like a stopwatch block.
    func add(start: Date, length: TimeInterval, tag: String?) {
        rewrite(FocusSession(startedAt: start, endedAt: start + length, focusSeconds: length,
                             plannedSeconds: 0, completed: true, tag: Self.cleanTag(tag),
                             deviceID: deviceID, updatedAt: Date()))
    }

    /// The tag a new block starts with.
    var suggestedTag: String { tagFilter ?? tag }

    private static func cleanTag(_ tag: String?) -> String? {
        let t = tag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return t.isEmpty ? nil : t
    }

    /// One day's sessions, oldest first, with the tag filter applied.
    func sessions(on day: Date) -> [FocusSession] {
        let start = builder.calendar.startOfDay(for: day)
        guard let end = builder.calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let all = (try? store.sessions(from: start, to: end)) ?? []
        return tagFilter.map { t in all.filter { $0.tag == t } } ?? all
    }

    private func rebuildHeatmap() {
        let shown = tagFilter.map { t in yearSessions.filter { $0.tag == t } } ?? yearSessions
        let built = builder.build(shown, today: Date())
        if built != heatmap { heatmap = built }
    }

    private enum Keys {
        static let config = "drill.config"
        static let intervals = "drill.intervals"
        static let tag = "drill.tag"
        static let sound = "drill.sound"
        static let theme = "drill.theme"
        static let mode = "drill.mode"
        static let goal = "drill.goal"
    }
}
