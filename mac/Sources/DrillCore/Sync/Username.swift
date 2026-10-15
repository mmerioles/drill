import Foundation

/// Account names: 3–20 of a-z, 0-9 and _, the same rule as the database.
public enum Username {
    public static let hint = "3–20 letters, digits or _"

    /// What the field keeps as you type: lowercase, no spaces.
    public static func clean(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    public static func isValid(_ name: String) -> Bool {
        (3...20).contains(name.count)
            && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
    }
}
