import AppKit
import UserNotifications

/// The "Time for a break" notification and its "Snooze 5 min" action.
///
/// Also Cai's `UNUserNotificationCenterDelegate`, installed at launch: without
/// a delegate a Snooze tap goes nowhere, and macOS hides banners while Cai is
/// the active app (the action panel may well be open when a break starts).
final class FocusBreakNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FocusBreakNotifier()

    private static let category = "cai-focus-break"
    private static let snoozeAction = "cai-focus-snooze"
    private static let requestID = "cai-focus-break"

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 5 min", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [snooze], intentIdentifiers: [], options: []),
        ])
    }

    /// Asked when the timer is turned on, not at launch. The Accessibility
    /// reminder may already have asked for alerts only; this adds sound.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Whether macOS will show the break notification; drives the note under
    /// the Focus Timer toggle in Settings.
    func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    func postBreak(_ phase: FocusPhase, minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = phase == .longBreak ? "Time for a long break" : "Time for a break"
        content.body = "Look away from the screen for \(minutes) minutes."
        content.sound = .default
        content.categoryIdentifier = Self.category
        // Same identifier every time, so a new break replaces the last banner.
        let request = UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Focus timer: break notification failed (\(error.localizedDescription))") }
        }
    }

    func removeBreakNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.requestID])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.snoozeAction {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { FocusTimerController.shared.send(.snooze) }
            }
        }
        completionHandler()
    }
}
