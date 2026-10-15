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

/// Passwords: 6+ characters (Supabase's floor) and at most 72 UTF-8 bytes (bcrypt's limit).
public enum Password {
    public static let hint = "6+ characters"

    public static func isValid(_ password: String) -> Bool {
        password.count >= 6 && password.utf8.count <= 72
    }

    /// Whether the second field repeats a valid first one.
    public static func confirms(_ confirm: String, _ password: String) -> Bool {
        isValid(password) && confirm == password
    }
}
