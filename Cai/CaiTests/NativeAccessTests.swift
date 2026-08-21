import EventKit
import XCTest
@testable import Cai

/// The decision logic behind the Connections screen's "System Access" tab.
///
/// Deliberately small, per the test-economy rule in `CLAUDE.md`. Only three
/// things here can ship a silent bug, so only three are tested:
///
/// 1. **Which domains may be requested** — a wrong mapping calls a request API
///    that doesn't exist (Accessibility, Automation) or can never exist (Full
///    Disk Access). The safety-relevant one.
/// 2. **The toggle state machine** — get it wrong and the app either never
///    prompts or fires a request that can't prompt.
/// 3. **The non-obvious EventKit status mappings** — a partial grant must not
///    read as ON.
///
/// Explicitly NOT tested, because each restates a mapping a reader can verify
/// by eye and would cost compile time on every build: the identity-shaped
/// Contacts status mapping, the macOS 13/14 version branch (unreachable at the
/// 14.0 deployment target), the three-case remediation-pane bridge, row
/// titles/icons/subtitles, and view layout.
final class NativeAccessTests: XCTestCase {

    typealias M = NativeAccessManager

    /// A domain Cai cannot request must never map to a requestable one.
    ///
    /// The `allCases` assertion is what makes this table trustworthy: without it
    /// a newly added key would simply be absent here and nothing would fail, so
    /// the "covers every key" claim would be a comment rather than a guarantee.
    func testRequestableDomainPerRemediationKey() {
        let cases: [(TCCRemediation.Domain.Key, M.Domain?)] = [
            (.calendars, .calendars),
            (.reminders, .reminders),   // requestable as of "Complete System Access"
            (.contacts, .contacts),
            (.appleEvents, nil),        // per-target, prompts on first use
            (.accessibility, nil),      // no request API beyond onboarding's
            (.fullDiskAccess, nil),     // no usage key, no request API — never
        ]
        XCTAssertEqual(
            Set(cases.map(\.0.rawValue)),
            Set(TCCRemediation.Domain.Key.allCases.map(\.rawValue)),
            "a new TCC domain key was added without deciding whether Cai may request it"
        )
        for (key, expected) in cases {
            XCTAssertEqual(M.requestableDomain(for: key), expected, "key \(key.rawValue)")
        }
    }

    /// Only `.notDetermined` may fire a real prompt; every other state routes to
    /// System Settings, because macOS exposes no API to re-request once the user
    /// has answered. `isOn` is asserted in the same table so a state can never
    /// read ON while its toggle would open Settings.
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

    /// The two EventKit statuses whose mapping is a judgment call rather than an
    /// identity. `.writeOnly` is a real grant that cannot satisfy Cai's stated
    /// benefit (reading events/reminders), so it must read OFF and guide to full
    /// access instead of lying ON; `.authorized` is the pre-macOS-14 spelling of
    /// "granted" and must not be mistaken for a partial grant.
    func testNonObviousEventKitStatusMappings() {
        XCTAssertEqual(M.state(from: EKAuthorizationStatus.writeOnly), .denied)
        XCTAssertEqual(M.state(from: EKAuthorizationStatus.authorized), .authorized)
    }
}
