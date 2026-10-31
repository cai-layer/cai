import XCTest
@testable import Cai

/// Keep Awake's decisions: what a click on the icon does, and what the icon
/// and menu say about the time left.
final class KeepAwakeTests: XCTestCase {

    // MARK: - Click routing (P1)

    /// P1: a wrong row turns the menu bar icon into a dead button, or takes
    /// Settings away from every user who never enabled Keep Awake.
    func testClickRouting() {
        let last = KeepAwakeDuration.minutes(30)
        // (enabled, isOn, expected)
        let cases: [(Bool, Bool, KeepAwakePolicy.ClickAction)] = [
            (false, false, .openSettings),
            // Disabling mid-run stops it elsewhere; a click must still open Settings.
            (false, true, .openSettings),
            (true, false, .start(last)),
            (true, true, .stop),
        ]
        for (enabled, isOn, expected) in cases {
            XCTAssertEqual(
                KeepAwakePolicy.clickAction(keepAwakeEnabled: enabled, isOn: isOn, lastDuration: last),
                expected, "enabled \(enabled), on \(isOn)"
            )
        }
    }

    // MARK: - Battery threshold (P1)

    /// P1: threshold edge and AC vs battery. Stopping on the charger, or not
    /// stopping below the threshold, is exactly the bug the setting exists for.
    func testBatteryThreshold() {
        // (onBattery, percent, enabled, threshold, stops)
        let cases: [(Bool, Int, Bool, Int, Bool)] = [
            (true, 9, true, 10, true),
            (true, 10, true, 10, false),  // "below" is strict
            (true, 49, true, 50, true),
            (false, 3, true, 10, false),  // on the charger: never
            (true, 3, false, 10, false),  // setting off: never
        ]
        for (onBattery, percent, enabled, threshold, stops) in cases {
            XCTAssertEqual(
                KeepAwakePolicy.shouldStopForBattery(onBattery: onBattery, percent: percent, thresholdEnabled: enabled, threshold: threshold),
                stops, "battery \(onBattery), \(percent)% vs \(threshold)%, enabled \(enabled)"
            )
        }
    }

    // MARK: - Time left (P1)

    /// P1: clamping. The curtain must never draw below empty or above full,
    /// and the menu must never say "0 min left" while the Mac is still held.
    func testTimeLeft() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let thirty = KeepAwakeState.on(startedAt: start, duration: .minutes(30))
        let fiveHours = KeepAwakeState.on(startedAt: start, duration: .minutes(300))
        let noLimit = KeepAwakeState.on(startedAt: start, duration: .indefinitely)

        // (state, seconds since start, fraction left, expired, header)
        let cases: [(KeepAwakeState, TimeInterval, Double?, Bool, String?)] = [
            (.off, 0, nil, false, nil),
            (thirty, 0, 1, false, "Keep Awake: 30 min left"),
            (thirty, 900, 0.5, false, "Keep Awake: 15 min left"),
            // The last minute rounds up.
            (thirty, 1790, 10.0 / 1800, false, "Keep Awake: 1 min left"),
            (thirty, 1800, 0, true, "Keep Awake: 1 min left"),
            // A clock step back or a late timer: clamped, not negative or >1.
            (thirty, 4000, 0, true, "Keep Awake: 1 min left"),
            (thirty, -60, 1, false, "Keep Awake: 30 min left"),
            (fiveHours, 3600 * 2 + 60 * 49 + 30, 7830.0 / 18000, false, "Keep Awake: 2 h 11 min left"),
            (fiveHours, 3600 * 4, 0.2, false, "Keep Awake: 1 h left"),
            (noLimit, 99_999, nil, false, "Keep Awake: No limit"),
        ]
        for (state, elapsed, fraction, expired, header) in cases {
            let now = start.addingTimeInterval(elapsed)
            let label = "\(state) at \(elapsed)s"
            if let fraction {
                XCTAssertEqual(state.remainingFraction(now: now) ?? -1, fraction, accuracy: 0.0001, label)
            } else {
                XCTAssertNil(state.remainingFraction(now: now), label)
            }
            XCTAssertEqual(state.isExpired(now: now), expired, label)
            XCTAssertEqual(state.menuHeader(now: now), header, label)
        }
    }
}
