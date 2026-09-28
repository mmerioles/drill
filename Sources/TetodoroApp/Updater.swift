import AppKit
import Foundation
import Observation
import TetodoroCore

/// Keeps the app current from GitHub releases, with no dependencies: finds
/// the newest release, downloads its dmg, swaps the app bundle in place and
/// relaunches. Your sessions live in Application Support and are untouched.
///
/// It checks at launch and every few hours after. When the app can't replace
/// itself (a folder you can't write to, or run straight from the dmg), update
/// opens the release page instead.
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

    private static let latest = URL(string: "https://api.github.com/repos/mmerioles/tetodoro/releases/latest")!
    private static let every: Duration = .seconds(6 * 3600)

    private let bundle: URL
    private var loop: Task<Void, Never>?

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
                try? await Task.sleep(for: Self.every)
            }
        }
    }

    /// `quietly` keeps a failed background check from showing an error.
    func check(quietly: Bool = false) async {
        guard isEnabled, let current, state != .checking, state != .installing else { return }
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            state = release.version > current ? .available(release) : .upToDate
        } catch {
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

    /// The folder holding the app must be writable, which also rules out
    /// running from the dmg or from a translocated copy.
    private var canReplaceSelf: Bool {
        FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// Downloads and mounts the dmg, and copies the new app next to this one
    /// so the swap is a rename on the same volume.
    private func stage(_ release: Release) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "tetodoro-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (download, _) = try await URLSession.shared.download(from: release.dmg)
        let dmg = work.appending(path: "update.dmg")
        try fm.moveItem(at: download, to: dmg)

        let mount = work.appending(path: "mnt")
        try await Self.run("/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen", "-readonly",
                           "-mountpoint", mount.path, dmg.path)
        do {
            let staged = try await copyApp(from: mount)
            try await Self.run("/usr/bin/hdiutil", "detach", "-force", mount.path)
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

        let staged = bundle.deletingLastPathComponent().appending(path: ".Tetodoro-update.app")
        try? fm.removeItem(at: staged)
        try await Self.run("/usr/bin/ditto", app.path, staged.path)
        return staged
    }

    /// Moves this app aside, puts the new one in its place, then throws the
    /// old one away. If the second move fails the old app goes back.
    private func swap(in staged: URL) throws {
        let fm = FileManager.default
        let old = bundle.deletingLastPathComponent().appending(path: ".Tetodoro-old.app")
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

    /// Opens the new app once this process has gone, then quits.
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
