import AppKit
import Foundation
import Observation
import DrillCore

/// Self-update from GitHub releases: downloads the dmg, swaps the bundle in
/// place and relaunches. Checks at launch, hourly, on return to the app, and
/// in settings. If the app can't replace itself, opens the release page.
@Observable @MainActor
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing
        case failed(String)
    }

    struct Release: Equatable {
        var version: Version
        var dmg: URL
        var page: URL
    }

    private(set) var state = State.idle
    let current: Version?

    private static let latest = URL(string: "https://api.github.com/repos/mmerioles/drill/releases/latest")!
    private static let every: Duration = .seconds(3600)
    private static let stale: TimeInterval = 15 * 60

    private let bundle: URL
    private var loop: Task<Void, Never>?
    private var lastChecked: Date?

    init(bundle: Bundle = .main) {
        self.bundle = bundle.bundleURL
        self.current = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(Version.init)
    }

    /// Only a real .app can update itself; `swift run` builds can't.
    var isEnabled: Bool { bundle.pathExtension == "app" && current != nil }

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    func start() {
        guard isEnabled, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(quietly: true)
                try? await Task.sleep(for: Self.every, tolerance: .seconds(360))
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfStale(Self.stale) }
        }
    }

    /// A quiet check, unless one ran within `age` seconds.
    func checkIfStale(_ age: TimeInterval = 60) {
        if case .available = state { return } // already found one
        guard lastChecked.map({ -$0.timeIntervalSinceNow > age }) ?? true else { return }
        Task { await check(quietly: true) }
    }

    /// `quietly` hides failures. A requested check spins at least a moment,
    /// so the answer reads as one.
    func check(quietly: Bool = false) async {
        guard isEnabled, let current, state != .checking, state != .installing else { return }
        state = .checking
        lastChecked = Date()
        let settle = ContinuousClock.now + (quietly ? .zero : .milliseconds(900))
        let release: Release?
        do { release = try await Self.fetchLatest() } catch { release = nil }
        try? await Task.sleep(until: settle, clock: .continuous)
        if let release {
            state = release.version > current ? .available(release) : .upToDate
        } else {
            state = quietly ? .idle : .failed("couldn't check for updates.")
        }
    }

    func install() async {
        guard let release = available else { return }
        guard canReplaceSelf else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .installing
        do {
            let staged = try await stage(release)
            try swap(in: staged)
            relaunch()
        } catch {
            // Don't leave a half-copied app lying next to this one.
            try? FileManager.default.removeItem(at: stagedURL)
            state = .failed("update didn't finish. try again, or grab the dmg.")
        }
    }

    // MARK: Steps

    private static func fetchLatest() async throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable { var name: String; var browser_download_url: URL }
            var tag_name: String
            var html_url: URL
            var assets: [Asset]
        }
        var request = URLRequest(url: latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let version = Version(payload.tag_name),
              let dmg = payload.assets.first(where: { $0.name.hasSuffix(".dmg") })
        else { throw URLError(.cannotParseResponse) }
        return Release(version: version, dmg: dmg.browser_download_url, page: payload.html_url)
    }

    /// Also rules out running from the dmg or a translocated copy.
    private var canReplaceSelf: Bool {
        FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// Copies the new app next to this one, so the swap is a same-volume rename.
    private func stage(_ release: Release) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "drill-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (download, response) = try await URLSession.shared.download(from: release.dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? fm.removeItem(at: download)
            throw URLError(.badServerResponse)
        }
        let dmg = work.appending(path: "update.dmg")
        try fm.moveItem(at: download, to: dmg)

        let mount = work.appending(path: "mnt")
        try await Self.run("/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen", "-readonly",
                           "-mountpoint", mount.path, dmg.path)
        do {
            let staged = try await copyApp(from: mount)
            // The copy is done; a stuck mount mustn't sink the update.
            try? await Self.run("/usr/bin/hdiutil", "detach", "-force", mount.path)
            return staged
        } catch {
            try? await Self.run("/usr/bin/hdiutil", "detach", "-force", mount.path)
            throw error
        }
    }

    private func copyApp(from mount: URL) async throws -> URL {
        let fm = FileManager.default
        guard let app = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
        else { throw CocoaError(.fileReadCorruptFile) }

        let staged = stagedURL
        try? fm.removeItem(at: staged)
        try await Self.run("/usr/bin/ditto", app.path, staged.path)
        // Ad-hoc signed is fine; a damaged or tampered bundle is not.
        try await Self.run("/usr/bin/codesign", "--verify", "--strict", staged.path)
        return staged
    }

    private var stagedURL: URL {
        bundle.deletingLastPathComponent().appending(path: ".Drill-update.app")
    }

    /// If the second move fails, the old app goes back.
    private func swap(in staged: URL) throws {
        let fm = FileManager.default
        let old = bundle.deletingLastPathComponent().appending(path: ".Drill-old.app")
        try? fm.removeItem(at: old)
        try fm.moveItem(at: bundle, to: old)
        do {
            try fm.moveItem(at: staged, to: bundle)
        } catch {
            try? fm.moveItem(at: old, to: bundle)
            try? fm.removeItem(at: staged)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    private func relaunch() {
        let wait = Process()
        wait.executableURL = URL(filePath: "/bin/sh")
        wait.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; open "$2""#,
                          "sh", "\(ProcessInfo.processInfo.processIdentifier)", bundle.path]
        try? wait.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func run(_ tool: String, _ args: String...) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(filePath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        }.value
    }
}
