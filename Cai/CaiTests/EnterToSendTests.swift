import XCTest
import AppKit
@testable import Cai

/// Unit tests for the app-wide "Return to submit" decision logic (issue #32).
/// Exercises `WindowController.returnSubmitsPrompt`, the shared pure function the
/// window key monitor and the form editors (`ForwardingTextView`) both use to
/// decide submit-vs-newline for a Return. Only a *bare* Return submits; any
/// modifier inserts a newline. (Cmd+Return is handled separately upstream and
/// always submits, so it's not modeled here.)
final class EnterToSendTests: XCTestCase {

    // MARK: - Setting OFF (default): Return always inserts a newline

    func testReturnInsertsNewlineWhenSettingOff() {
        // Composer active, no modifiers — but the setting is off, so Return = newline.
        XCTAssertFalse(
            WindowController.returnSubmitsPrompt(
                pressReturnToSend: false, submitScreenActive: true, modifiers: []
            ),
            "With the setting off, a bare Return must insert a newline, not submit."
        )
    }

    func testShiftReturnInsertsNewlineWhenSettingOff() {
        XCTAssertFalse(
            WindowController.returnSubmitsPrompt(
                pressReturnToSend: false, submitScreenActive: true, modifiers: [.shift]
            )
        )
    }

    // MARK: - Setting ON: a bare Return submits, Shift+Return inserts a newline

    func testBareReturnSubmitsWhenSettingOnAndComposerActive() {
        XCTAssertTrue(
            WindowController.returnSubmitsPrompt(
                pressReturnToSend: true, submitScreenActive: true, modifiers: []
            ),
            "With the setting on in an Ask AI composer, a bare Return must submit."
        )
    }

    func testShiftReturnInsertsNewlineWhenSettingOn() {
        XCTAssertFalse(
            WindowController.returnSubmitsPrompt(
                pressReturnToSend: true, submitScreenActive: true, modifiers: [.shift]
            ),
            "Shift+Return must always insert a newline, even with the setting on."
        )
    }

    // MARK: - Setting ON: only a *bare* Return submits — other modifiers insert a newline

    func testOptionReturnInsertsNewlineWhenSettingOn() {
        XCTAssertFalse(
            WindowController.returnSubmitsPrompt(
                pressReturnToSend: true, submitScreenActive: true, modifiers: [.option]
            ),
            "Option+Return must insert a newline — only a bare Return submits."
        )
    }

    func testControlReturnInsertsNewlineWhenSettingOn() {
        XCTAssertFalse(
            WindowController.returnSubmitsPrompt(
                pressReturnToSend: true, submitScreenActive: true, modifiers: [.control]
            ),
            "Control+Return must insert a newline — only a bare Return submits."
        )
    }

    func testCapsLockDoesNotBlockSubmitWhenSettingOn() {
        // CapsLock isn't an intentional modifier for this gesture — a Return with
        // only CapsLock active is still a "bare" Return and must submit.
        XCTAssertTrue(
            WindowController.returnSubmitsPrompt(
                pressReturnToSend: true, submitScreenActive: true, modifiers: [.capsLock]
            ),
            "CapsLock must not block submit — only Shift/Option/Control do."
        )
    }

    // MARK: - Scoping: the setting only affects the Ask AI composers

    func testReturnInsertsNewlineOutsideComposerEvenWhenSettingOn() {
        // Other text-input screens (destination/MCP/shortcut forms) must keep
        // Return = newline regardless of the setting.
        XCTAssertFalse(
            WindowController.returnSubmitsPrompt(
                pressReturnToSend: true, submitScreenActive: false, modifiers: []
            ),
            "Outside an Ask AI composer, Return must insert a newline even with the setting on."
        )
    }
}
