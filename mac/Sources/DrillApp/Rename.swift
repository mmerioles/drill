import Foundation
import DrillCore

/// The app was called tetodoro until v0.9. On the first launch as drill,
/// this carries over what the old name kept, so nothing is lost: the
/// sessions database, and the settings, sync login and device id in the old
/// app's defaults. The old names live only here.
enum Rename {
    private static let oldDomain = "com.mmerioles.tetodoro"
    private static let oldPrefix = "tetodoro."
    private static let oldFolder = "Tetodoro"
    private static let oldDatabase = "tetodoro.sqlite"
    private static let done = "drill.renamed"

    /// Runs once, before anything opens the database or reads defaults.
    static func carryOver(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: done) else { return }
        moveDatabase()
        if let old = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in old where key.hasPrefix(oldPrefix) {
                let new = "drill." + key.dropFirst(oldPrefix.count)
                if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
            }
        }
        defaults.set(true, forKey: done)
    }

    /// Moves Application Support/Tetodoro/tetodoro.sqlite (and its WAL files)
    /// to where drill looks, unless drill already has a database.
    private static func moveDatabase() {
        let fm = FileManager.default
        let new = SQLiteSessionStore.defaultURL
        let oldDir = URL.applicationSupportDirectory.appending(path: oldFolder, directoryHint: .isDirectory)
        let old = oldDir.appending(path: oldDatabase)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let from = URL(filePath: old.path + suffix)
                guard fm.fileExists(atPath: from.path) else { continue }
                try fm.moveItem(at: from, to: URL(filePath: new.path + suffix))
            }
            if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true {
                try? fm.removeItem(at: oldDir)
            }
        } catch {
            // Whatever didn't move stays in the old folder, untouched.
        }
    }
}
