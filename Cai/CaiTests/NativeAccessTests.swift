import Contacts
import EventKit
import XCTest
@testable import Cai

/// The decision logic behind the Connections screen's "System Access" tab: raw
/// framework status → UI state, the macOS-version request branch, what a toggle
/// tap should do, and which domains runtime remediation may *request* versus only
/// guide toward. Pulled out of the live app so it's verified here instead of only
/// against real system state.
///
/// Table-driven per the test-economy rule in `CLAUDE.md`: one table per decision
/// rather than a method per case, so adding a domain adds rows, not funcs.
final class NativeAccessTests: XCTestCase {

    typealias M = NativeAccessManager

    // MARK: - Raw framework status → UI state

    func testEventKitStatusMapsToAccessState() {
        let cases: [(EKAuthorizationStatus, M.AccessState)] = [
            (.notDetermined, .notDetermined),
            (.restricted, .restricted),
            (.denied, .denied),
            (.fullAccess, .authorized),
            (.authorized, .authorized),   // legacy (pre-14) "granted"
            // Cai's Calendar/Reminders benefit promises reading; write-only
            // can't satisfy it, so the toggle must read OFF and guide to full
            // access rather than lying ON.
            (.writeOnly, .denied),
        ]
        for (status, expected) in cases {
            XCTAssertEqual(M.state(from: status), expected, "EK status \(status.rawValue)")
        }
    }

    func testContactsStatusMapsToAccessState() {
        let cases: [(CNAuthorizationStatus, M.AccessState)] = [
            (.notDetermined, .notDetermined),
            (.restricted, .restricted),
            (.denied, .denied),
            (.authorized, .authorized),
        ]
        for (status, expected) in cases {
            XCTAssertEqual(M.state(from: status), expected, "CN status \(status.rawValue)")
        }
    }

    // MARK: - Toggle intent + isOn

    /// Only `.notDetermined` can fire a real prompt; every other state routes to
    /// System Settings because macOS exposes no API to re-request once answered.
    /// `isOn` is asserted in the same table so a state can never read ON while
    /// its toggle would open Settings.
    func testToggleIntentAndIsOnPerState() {
        let cases: [(M.AccessState, M.ToggleIntent, Bool)] = [
            (.notDetermined, .request, false),
            (.authorized, .openSettings, true),
            (.denied, .openSettings, false),
            (.restricted, .openSettings, false),
        ]
        for (state, intent, isOn) in cases {
            XCTAssertEqual(M.toggleIntent(for: state), intent, "intent for \(state)")
            XCTAssertEqual(state.isOn, isOn, "isOn for \(state)")
        }
    }

    // MARK: - macOS-version request branch

    func testEventKitRequestStrategyByMajorVersion() {
        let cases: [(Int, M.EventKitRequestStrategy)] = [
            (13, .legacy),
            (14, .fullAccess),
            (26, .fullAccess),
        ]
        for (version, expected) in cases {
            XCTAssertEqual(M.eventKitRequestStrategy(macOSMajorVersion: version), expected, "macOS \(version)")
        }
    }

    // MARK: - Requestable vs guide-only

    /// The safety-relevant half: a domain Cai cannot request must never map to a
    /// requestable one, or `offerGrantIfPossible` would call a request API that
    /// doesn't exist (Accessibility, Automation) or can't exist (Full Disk
    /// Access). Covers every key so a new one can't be added silently.
    func testRequestableDomainPerRemediationKey() {
        let cases: [(TCCRemediation.Domain.Key, M.Domain?)] = [
            (.calendars, .calendars),
            (.reminders, .reminders),   // requestable as of "Complete System Access"
            (.contacts, .contacts),
            (.appleEvents, nil),        // per-target, prompts on first use
            (.accessibility, nil),      // no request API beyond onboarding's
            (.fullDiskAccess, nil),     // no usage key, no request API — never
        ]
        for (key, expected) in cases {
            XCTAssertEqual(M.requestableDomain(for: key), expected, "key \(key.rawValue)")
        }
    }

    /// Every grantable domain must bridge to a remediation domain with the
    /// matching pane, which is the whole reason the bridge init exists.
    func testEveryGrantableDomainBridgesToItsOwnRemediationPane() {
        let expected: [M.Domain: TCCRemediation.Domain.Key] = [
            .calendars: .calendars,
            .reminders: .reminders,
            .contacts: .contacts,
        ]
        for domain in M.Domain.allCases {
            XCTAssertEqual(TCCRemediation.Domain(domain).key, expected[domain], "bridge for \(domain.rawValue)")
            XCTAssertEqual(domain.settingsURL, TCCRemediation.Domain(domain).settingsURL)
        }
    }

    // MARK: - Read-only system rows

    /// Accessibility reports a real status; Automation must report **none**. A
    /// word in the status slot would read as a state Cai verified, but Apple
    /// Events grants are per (source, target) pair with no app-level truth
    /// available without Full Disk Access.
    func testSystemDomainStatusText() {
        XCTAssertEqual(M.SystemDomain.accessibility.statusText(accessibilityGranted: true), "Granted")
        XCTAssertEqual(M.SystemDomain.accessibility.statusText(accessibilityGranted: false), "Not granted")
        XCTAssertNil(M.SystemDomain.automation.statusText(accessibilityGranted: true))
        XCTAssertNil(M.SystemDomain.automation.statusText(accessibilityGranted: false))
    }

    /// A read-only row's Open button is its only affordance, so a wrong pane
    /// makes the row useless.
    func testSystemDomainSettingsPanes() {
        XCTAssertEqual(M.SystemDomain.accessibility.settingsURL, TCCRemediation.Domain.accessibility.settingsURL)
        XCTAssertEqual(M.SystemDomain.automation.settingsURL, TCCRemediation.Domain.appleEvents.settingsURL)
    }
}
