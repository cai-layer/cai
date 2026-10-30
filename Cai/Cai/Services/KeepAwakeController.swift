import AppKit
import IOKit.pwr_mgt

extension Notification.Name {
    /// Keep Awake started, stopped, or its curtain moved. The status item redraws.
    static let caiKeepAwakeChanged = Notification.Name("caiKeepAwakeChanged")
}

/// Holds the power assertion behind Keep Awake (the Caffeine-style mode on the
/// menu bar icon).
///
/// One IOKit assertion, never a `caffeinate` child process: the kernel drops
/// an assertion when its process dies, so a crash cannot leave the Mac stuck
/// awake.
@MainActor
final class KeepAwakeController {
    static let shared = KeepAwakeController()

    private(set) var state: KeepAwakeState = .off
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var expiryTimer: Timer?
    private var redrawTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        // Timers don't fire on time across sleep, so a run that ended while
        // the lid was closed is settled on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopIfExpired() }
        }
    }

    func start(_ duration: KeepAwakeDuration, now: Date = Date()) {
        CaiSettings.shared.keepAwakeLastMinutes = duration.storedMinutes
        state = .on(startedAt: now, duration: duration)
        takeAssertion()
        scheduleTimers(for: duration)
        notify()
    }

    func stop() {
        guard state.isOn else { return }
        state = .off
        releaseAssertion()
        invalidateTimers()
        notify()
    }

    /// "Let the display sleep" changed: swap the assertion type in place.
    func displaySleepSettingChanged() {
        guard hasAssertion else { return }
        releaseAssertion()
        takeAssertion()
    }

    // MARK: - Private

    private func takeAssertion() {
        releaseAssertion()
        let type = CaiSettings.shared.keepAwakeAllowsDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Cai Keep Awake" as CFString,
            &assertionID
        )
        hasAssertion = result == kIOReturnSuccess
        if !hasAssertion {
            print("Keep Awake: IOPMAssertionCreateWithName failed (\(result))")
        }
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
    }

    private func scheduleTimers(for duration: KeepAwakeDuration) {
        invalidateTimers()
        guard let total = duration.seconds, let step = KeepAwakePolicy.redrawInterval(for: duration) else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: total, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        redrawTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.state.isExpired(now: Date()) { self.stop() } else { self.notify() }
            }
        }
    }

    private func invalidateTimers() {
        expiryTimer?.invalidate()
        redrawTimer?.invalidate()
        expiryTimer = nil
        redrawTimer = nil
    }

    private func stopIfExpired() {
        if state.isExpired(now: Date()) { stop() } else if state.isOn { notify() }
    }

    private func notify() {
        NotificationCenter.default.post(name: .caiKeepAwakeChanged, object: nil)
    }
}
