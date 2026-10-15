import Foundation
import UserNotifications
import DrillCore

/// Schedules the phase-end banner ahead of time, so it lands on time even if
/// the Mac just woke. A no-op outside an .app bundle (`swift run`).
@MainActor
final class Notifier {
    /// The banner's start button, with the phase it offered.
    var onStart: ((Phase) -> Void)? {
        get { delegate.onStart }
        set { delegate.onStart = newValue }
    }

    private var authorized: Task<Void, Never>?
    /// Bumped on schedule and cancel, so a schedule waiting on permission
    /// can't add a banner cancelled meanwhile.
    private var generation = 0
    private let delegate = Banners()
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// One id per kind of phase: banners replace rather than pile up, and a
    /// delivered focus banner survives scheduling the break it started.
    nonisolated static let focusID = "drill.end.focus"
    nonisolated static let breakID = "drill.end.break"
    nonisolated static let startAction = "drill.start"
    nonisolated static let offeredKey = "drill.offered"
    private static let nextBreak = "drill.next.break"
    private static let nextFocus = "drill.next.focus"

    init() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        // Drop banners left by a crash or force quit.
        center.removePendingNotificationRequests(withIdentifiers: [Self.focusID, Self.breakID])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.nextBreak,
                actions: [UNNotificationAction(identifier: Self.startAction, title: Copy.startNext(.shortBreak))],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Self.nextFocus,
                actions: [UNNotificationAction(identifier: Self.startAction, title: Copy.startNext(.focus))],
                intentIdentifiers: []),
        ])
    }

    /// Asks for permission the first time a timer starts, not at launch.
    func prepare() {
        guard available, authorized == nil else { return }
        // Not the completion handler: it'd be main-actor isolated but called on
        // a background queue, which Swift 6 traps on.
        authorized = Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// `next` is offered as a start button, when it won't auto-start.
    func schedule(title: String, body: String, breakEnding: Bool, at endsAt: Date, offering next: Phase?) {
        guard available else { return }
        prepare()
        generation += 1
        let mine = generation
        Task {
            await authorized?.value
            guard mine == generation else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let next {
                content.categoryIdentifier = next.isBreak ? Self.nextBreak : Self.nextFocus
                content.userInfo = [Self.offeredKey: next.rawValue]
            }
            // No sound: the app plays it, honouring the setting. A nil trigger
            // would deliver at once, so always at least a second out.
            let wait = max(1, endsAt.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: breakEnding ? Self.breakID : Self.focusID,
                                      content: content, trigger: trigger))
        }
    }

    func cancel() {
        generation += 1
        guard available else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.focusID, Self.breakID])
    }
}

/// Shows banners while frontmost, and handles the start button.
@MainActor
private final class Banners: NSObject, UNUserNotificationCenterDelegate {
    var onStart: ((Phase) -> Void)?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Notifier.startAction,
              let raw = response.notification.request.content.userInfo[Notifier.offeredKey] as? String,
              let offered = Phase(rawValue: raw) else { return }
        await MainActor.run { self.onStart?(offered) }
    }
}
