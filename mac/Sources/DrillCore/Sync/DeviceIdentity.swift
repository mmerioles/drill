import Foundation

/// A stable per-install id stamped on every session.
public enum DeviceIdentity {
    private static let key = "drill.deviceID"

    public static func current(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: key) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}
