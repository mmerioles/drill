import Foundation

/// Account emails: something@somewhere.tld, at most 254 characters.
public enum Email {
    public static let hint = "not an email address"

    /// What the field keeps as you type: lowercase, no spaces.
    public static func clean(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    public static func isValid(_ email: String) -> Bool {
        email.count <= 254 && email.wholeMatch(of: shape) != nil
    }

    nonisolated(unsafe) private static let shape = try! Regex(#"[^\s@]+@[^\s@]+\.[^\s@]+"#)
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
