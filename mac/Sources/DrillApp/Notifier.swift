import Foundation
import UserNotifications
import DrillCore

/// Schedules the "focus done" / "break over" banner for the moment a phase
/// ends, so it lands on time even if the app is busy or the Mac just woke.
/// Silently does nothing when running outside an .app bundle (e.g.
/// `swift run`), where UserNotifications is unavailable.
@MainActor
final class Notifier {
    /// Called when the banner's "start break" / "start focus" is clicked.
    var onStart: (() -> Void)? {
        get { delegate.onStart }
        set { delegate.onStart = newValue }
    }

    private var authorized: Task<Void, Never>?
    /// Bumped on every schedule and cancel, so a schedule still waiting on
    /// permission can't add a banner that was cancelled meanwhile.
    private var generation = 0
    private let delegate = Banners()
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// One fixed identifier per kind of phase, so banners replace each other
    /// instead of piling up, and a focus banner just delivered isn't pulled
    /// back when the break it started is scheduled.
    nonisolated static let focusID = "drill.end.focus"
    nonisolated static let breakID = "drill.end.break"
    nonisolated static let startAction = "drill.start"
    private static let nextBreak = "drill.next.break"
    private static let nextFocus = "drill.next.focus"

    init() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
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
        // The async form, not the completion handler: a closure written here is
        // main-actor isolated, and the system calls it on a background queue,
        // which Swift 6 traps on at runtime.
        authorized = Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// The banner for the phase that ends at `endsAt`. `next` offers its
    /// start button when it won't start by itself.
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
            if let next { content.categoryIdentifier = next.isBreak ? Self.nextBreak : Self.nextFocus }
            // The sound is played by the app itself, so it honours the sound setting.
            let wait = endsAt.timeIntervalSinceNow
            let trigger = wait >= 1 ? UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false) : nil
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: breakEnding ? Self.breakID : Self.focusID,
                                      content: content, trigger: trigger))
        }
    }

    /// Drops any banner still waiting to go off, e.g. on pause or reset.
    func cancel() {
        generation += 1
        guard available else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.focusID, Self.breakID])
    }
}

/// Shows banners while drill is frontmost, and hears the start button.
@MainActor
private final class Banners: NSObject, UNUserNotificationCenterDelegate {
    var onStart: (() -> Void)?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Notifier.startAction else { return }
        await MainActor.run { self.onStart?() }
    }
}
