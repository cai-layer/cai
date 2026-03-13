import Cocoa
import Sparkle

/// Manages automatic updates via Sparkle.
/// Replaces the old UpdateChecker which only notified — this one downloads and installs.
///
/// For background/LSUIElement apps, Sparkle won't pop a dialog on its own during
/// scheduled checks. Instead, we implement gentle reminders: show a persistent banner
/// in the action list, and when the user clicks it, open Sparkle's standard update dialog.
final class SparkleUpdater: NSObject, ObservableObject {
    static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController
    private let driverDelegate = DriverDelegate()

    /// Whether "Check for Updates" can be clicked right now
    @Published var canCheckForUpdates = false

    /// True when a scheduled check found an update — drives the in-app banner
    @Published var updateAvailable = false

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
        )
        super.init()

        driverDelegate.onUpdateFound = { [weak self] in
            DispatchQueue.main.async {
                self?.updateAvailable = true
            }
        }
        driverDelegate.onUpdateDismissed = { [weak self] in
            DispatchQueue.main.async {
                self?.updateAvailable = false
            }
        }

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Opens Sparkle's standard update dialog (check → download → install & restart).
    /// Wire this to "Check for Updates" buttons and the update banner.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

// MARK: - Gentle Reminder Delegate

/// Separate class because SPUStandardUpdaterController takes the delegate in init,
/// before `self` is available.
private class DriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var onUpdateFound: (() -> Void)?
    var onUpdateDismissed: (() -> Void)?

    /// Tell Sparkle we handle gentle reminders for scheduled (background) checks.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Called when Sparkle wants to show an update.
    /// - handleShowingUpdate == true: scheduled check → we show our banner
    /// - handleShowingUpdate == false: user-initiated → Sparkle shows its own dialog
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            onUpdateFound?()
        }
    }

    /// Called when Sparkle's update session ends (installed, dismissed, or errored).
    func standardUserDriverWillFinishUpdateSession() {
        onUpdateDismissed?()
    }
}
