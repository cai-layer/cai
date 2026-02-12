import Cocoa
import ApplicationServices
import UserNotifications

class PermissionsManager: ObservableObject {
    @Published var hasAccessibilityPermission: Bool = false
    private var pollTimer: Timer?
    private var reminderScheduled = false

    static let shared = PermissionsManager()

    /// UserDefaults key to track if we already sent the one-time reminder.
    private static let reminderSentKey = "cai_accessibilityReminderSent"

    private init() {
        checkAccessibilityPermission()
    }

    func checkAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)

        if hasAccessibilityPermission {
            print("✅ Accessibility permission granted")
        } else {
            print("⚠️ Accessibility permission not granted")
        }
    }

    func requestAccessibilityPermission() {
        // Trigger the system prompt once — this registers Cai in System Settings
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)

        if hasAccessibilityPermission {
            print("✅ Accessibility permission granted after request")
        } else {
            print("⚠️ Accessibility permission prompt shown - waiting for user")
        }
    }

    func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        Cai needs accessibility permission for the ⌥C hotkey to work.

        Enable Cai in System Settings → Accessibility.
        """
        alert.alertStyle = .informational
        if let logo = NSImage(named: "CaiLogo") {
            alert.icon = logo
        }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open System Settings
            openAccessibilityPreferences()
        }
    }

    func openAccessibilityPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Polls for permission changes every 2 seconds until granted.
    /// Menu bar apps (LSUIElement) don't reliably receive didBecomeActiveNotification,
    /// so we poll instead.
    func startPollingForPermission() {
        guard !hasAccessibilityPermission else { return }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let hadPermission = self.hasAccessibilityPermission
            self.checkAccessibilityPermission()

            if self.hasAccessibilityPermission {
                timer.invalidate()
                self.pollTimer = nil
                self.cancelPermissionReminder()
                if !hadPermission {
                    NotificationCenter.default.post(
                        name: .accessibilityPermissionChanged,
                        object: nil
                    )
                }
            }
        }
    }

    // MARK: - Permission Reminder Notification

    /// Schedules a one-time local notification after 5 minutes if the user
    /// hasn't granted Accessibility permission yet. Only fires once — ever.
    func schedulePermissionReminderIfNeeded() {
        guard !hasAccessibilityPermission,
              !reminderScheduled,
              !UserDefaults.standard.bool(forKey: Self.reminderSentKey) else { return }

        reminderScheduled = true

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                print("Notification permission not granted — skipping reminder")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Cai needs Accessibility permission"
            content.body = "Enable it in System Settings to start using ⌥C."

            // Fire after 5 minutes
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)
            let request = UNNotificationRequest(
                identifier: "cai-accessibility-reminder",
                content: content,
                trigger: trigger
            )

            center.add(request) { error in
                if let error = error {
                    print("Failed to schedule reminder: \(error)")
                } else {
                    UserDefaults.standard.set(true, forKey: Self.reminderSentKey)
                    print("Accessibility reminder scheduled (5 min)")
                }
            }
        }
    }

    /// Cancels any pending reminder — called when permission is granted.
    private func cancelPermissionReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["cai-accessibility-reminder"])
        print("Accessibility reminder cancelled — permission granted")
    }
}
