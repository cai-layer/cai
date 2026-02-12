import Cocoa
import UserNotifications

/// Checks GitHub releases once per day for a newer version of Cai.
/// Shows an indicator in Settings and sends a one-time notification.
class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// Non-nil when a newer version is available (e.g. "1.1.0").
    @Published var availableVersion: String? = nil

    // MARK: - UserDefaults Keys

    private static let lastCheckKey = "cai_lastUpdateCheck"
    private static let availableVersionKey = "cai_availableVersion"
    private static let notificationSentForKey = "cai_updateNotificationSentFor"

    private static let releasesURL = URL(string: "https://api.github.com/repos/soyasis/cai/releases/latest")!
    private static let releasePageURL = URL(string: "https://github.com/soyasis/cai/releases/latest")!

    private init() {
        // Restore cached available version (so Settings shows it before the network check)
        if let cached = UserDefaults.standard.string(forKey: Self.availableVersionKey) {
            let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if local.compare(cached, options: .numeric) == .orderedAscending {
                availableVersion = cached
            }
        }
    }

    // MARK: - Public

    /// Checks for a newer release. Throttled to once per 24 hours.
    func checkForUpdate() async {
        guard shouldCheck() else {
            print("Update check skipped — last check was < 24h ago")
            return
        }

        print("Checking for updates…")

        do {
            let (data, response) = try await URLSession.shared.data(from: Self.releasesURL)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("Update check failed — non-200 response")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                print("Update check failed — could not parse tag_name")
                return
            }

            // Record successful check time
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            // Strip leading "v" (e.g. "v1.1.0" → "1.1.0")
            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let localVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            if localVersion.compare(remoteVersion, options: .numeric) == .orderedAscending {
                print("Update available: v\(remoteVersion) (current: v\(localVersion))")

                await MainActor.run {
                    self.availableVersion = remoteVersion
                }

                // Cache so Settings can show it on next launch before the network check
                UserDefaults.standard.set(remoteVersion, forKey: Self.availableVersionKey)

                // One-time notification per version
                scheduleUpdateNotification(version: remoteVersion)
            } else {
                print("No update available (remote: v\(remoteVersion), local: v\(localVersion))")

                await MainActor.run {
                    self.availableVersion = nil
                }

                // Clear cached version
                UserDefaults.standard.removeObject(forKey: Self.availableVersionKey)
            }
        } catch {
            print("Update check failed: \(error.localizedDescription)")
        }
    }

    /// Opens the GitHub releases page in the default browser.
    func openReleasePage() {
        NSWorkspace.shared.open(Self.releasePageURL)
    }

    // MARK: - Private

    /// Returns true if at least 24 hours have passed since the last check.
    private func shouldCheck() -> Bool {
        guard let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date else {
            return true  // Never checked before
        }
        let elapsed = Date().timeIntervalSince(lastCheck)
        return elapsed >= 24 * 60 * 60  // 24 hours
    }

    /// Sends a one-time notification for a specific version.
    /// A new version triggers a new notification.
    private func scheduleUpdateNotification(version: String) {
        let sentFor = UserDefaults.standard.string(forKey: Self.notificationSentForKey)
        guard sentFor != version else {
            print("Update notification already sent for v\(version)")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                print("Notification permission not granted — skipping update notification")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Cai v\(version) is available"
            content.body = "Download the latest version from GitHub."

            let request = UNNotificationRequest(
                identifier: "cai-update-available",
                content: content,
                trigger: nil  // Fire immediately
            )

            center.add(request) { error in
                if let error = error {
                    print("Failed to send update notification: \(error)")
                } else {
                    UserDefaults.standard.set(version, forKey: Self.notificationSentForKey)
                    print("Update notification sent for v\(version)")
                }
            }
        }
    }
}
