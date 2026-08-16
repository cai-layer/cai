import XCTest
@testable import Cai

/// The runtime remediation detector: opaque action-failure text → the exact
/// System Settings pane. Conservative by design — it must fire on real TCC
/// denials and stay silent on ordinary command failures.
final class TCCRemediationTests: XCTestCase {

    // MARK: - Apple Events / Automation

    func testDetectsAppleEventsMinus1743() {
        let g = TCCRemediation.detect(in: "execution error: Not authorized to send Apple events (-1743)")
        XCTAssertEqual(g?.domain.key, .appleEvents)
        XCTAssertEqual(g?.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    func testDetectsAppleEventsBritishSpelling() {
        let g = TCCRemediation.detect(in: "Not authorised to send Apple events")
        XCTAssertEqual(g?.domain.key, .appleEvents)
    }

    // MARK: - EventKit / Contacts domains

    func testDetectsCalendarDenial() {
        let g = TCCRemediation.detect(in: "Error: No calendar access — access denied by the user")
        XCTAssertEqual(g?.domain.key, .calendars)
        XCTAssertEqual(g?.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    func testDetectsRemindersDenial() {
        let g = TCCRemediation.detect(in: "Reminders access not authorized")
        XCTAssertEqual(g?.domain.key, .reminders)
    }

    func testDetectsContactsDenial() {
        let g = TCCRemediation.detect(in: "CNContactStore: contacts access denied")
        XCTAssertEqual(g?.domain.key, .contacts)
    }

    func testDetectsRealWorldNoCalendarAccessMessage() {
        // The verbatim error an agent JXA Calendar action throws when denied —
        // the exact string a user hit live. Must map to Calendar (not nil).
        let msg = "execution error: Error: Error: No Calendar access. Grant it in System Settings > Privacy & Security > Calendars. (-2700)"
        XCTAssertEqual(TCCRemediation.detect(in: msg)?.domain.key, .calendars)
    }

    func testCalendarBeatsGenericAppleEventsCode() {
        // A Calendar denial that also carries -1743 must label as Calendar, not
        // generic Automation (domain-specific keywords are checked first).
        let g = TCCRemediation.detect(in: "Calendar access denied (-1743)")
        XCTAssertEqual(g?.domain.key, .calendars)
    }

    // MARK: - Full Disk Access (detect-only, never requestable)

    func testDetectsFullDiskAccessButOnlyGuides() {
        let g = TCCRemediation.detect(in: "This action needs Full Disk Access to read that file")
        XCTAssertEqual(g?.domain.key, .fullDiskAccess)
        XCTAssertEqual(g?.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        // The message must not promise Cai will request it.
        XCTAssertFalse(g?.message.lowercased().contains("cai will ask") ?? true)
    }

    // MARK: - Negative cases (no false positives)

    func testIgnoresOrdinaryCommandFailure() {
        XCTAssertNil(TCCRemediation.detect(in: "zsh: command not found: gh"))
    }

    func testIgnoresPlainCalendarMention() {
        // "calendar" without any denial phrase must NOT surface a permission pane.
        XCTAssertNil(TCCRemediation.detect(in: "Your calendar digest is ready with 4 events"))
    }

    func testIgnoresGenericTimeout() {
        XCTAssertNil(TCCRemediation.detect(in: "Shell command exceeded 60s and was stopped"))
    }

    // MARK: - Bridge to NativeAccessManager domains

    func testBridgeFromNativeDomainsUsesSamePane() {
        XCTAssertEqual(TCCRemediation.Domain(.calendars).settingsURL,
                       TCCRemediation.Domain.calendars.settingsURL)
        XCTAssertEqual(TCCRemediation.Domain(.contacts).settingsURL,
                       TCCRemediation.Domain.contacts.settingsURL)
    }
}
