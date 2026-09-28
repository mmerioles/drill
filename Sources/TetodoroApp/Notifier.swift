import Foundation
import UserNotifications

/// Posts "focus done" banners. Silently does nothing when running outside an
/// .app bundle (e.g. `swift run`), where UserNotifications is unavailable.
@MainActor
final class Notifier {
    private var prepared = false
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asks for permission the first time a timer starts, not at launch.
    func prepare() {
        guard available, !prepared else { return }
        prepared = true
        // The async form, not the completion handler: a closure written here is
        // main-actor isolated, and the system calls it on a background queue,
        // which Swift 6 traps on at runtime.
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
