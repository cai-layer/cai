import AppKit
import IOKit.ps
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
    private var powerSourceLoop: CFRunLoopSource?

    private init() {
        // Timers don't fire on time across sleep, so a run that ended while
        // the lid was closed is settled on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopIfExpired() }
        }

        // Battery level and AC/battery switches arrive here.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { KeepAwakeController.shared.checkBattery() }
            }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceLoop = source
        }
    }

    /// The internal battery's state, or nil on a Mac without one.
    static func batteryStatus() -> (onBattery: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (onBattery, current * 100 / max)
        }
        return nil
    }

    /// Re-checked on every power-source change and when the threshold
    /// setting changes. Not at start: a click on a low battery is the user's
    /// call, and the next change re-applies the rule.
    func checkBattery() {
        guard state.isOn, let battery = Self.batteryStatus() else { return }
        let settings = CaiSettings.shared
        if KeepAwakePolicy.shouldStopForBattery(
            onBattery: battery.onBattery,
            percent: battery.percent,
            thresholdEnabled: settings.keepAwakeStopsOnLowBattery,
            threshold: settings.keepAwakeBatteryThreshold
        ) {
            stop()
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
