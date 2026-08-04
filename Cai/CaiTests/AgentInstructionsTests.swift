import XCTest
import CaiActionCore

/// The handshake text every connected agent reads.
///
/// It ships inside the app and reaches models we do not control, so the things
/// worth pinning are the ones a well-meaning edit would break: the approval
/// boundary must stay stated, it has to stay short enough to leave in context
/// all session, and it must not drift into restating the tool schemas.
final class AgentInstructionsTests: XCTestCase {

    private var text: String { AgentInstructions.text }

    // MARK: - The parts an agent must not miss

    func testTheApprovalBoundaryIsStated() {
        XCTAssertTrue(text.contains("cannot approve, run, or delete"), "an agent that thinks it can approve its own proposals will tell the user the action is ready")
        XCTAssertTrue(text.contains("waits in Cai until the user"), "the inert-until-approved property is the whole security model")
    }

    func testTheAgentIsToldToHandOffAndThenPoll() {
        XCTAssertTrue(text.contains("tell the user"), "a proposal nobody is told about sits unread")
        XCTAssertTrue(text.contains("list_actions"), "there is no notification back, so polling is the only way to learn the outcome")
        XCTAssertTrue(text.contains("do not wait or poll"), "approval is human-scale; without this an agent busy-polls list_actions inside one turn")
    }

    func testTheEscalatedCasesCarryASelfCheck() {
        for risky in ["shell command", "opens a URL", "replaces the selection"] {
            XCTAssertTrue(text.contains(risky), "\(risky) should be called out before an agent proposes one")
        }
        XCTAssertTrue(text.contains("no secrets"), "the value is the field where a credential leaks into a stored action")
    }

    func testTheHotkeyIsNamedSoTheAgentCanExplainTheFeature() {
        XCTAssertTrue(text.contains("Option+C"), "agents relay this to users who have never opened Cai")
    }

    // MARK: - Staying cheap enough to keep resident

    func testItIsShortEnoughToSitInContextAllSession() {
        XCTAssertLessThan(text.count, 2_000, "instructions are resident for the whole session; long ones tax every request")
    }

    func testItDoesNotRestateTheToolSchemas() {
        for perToolDetail in ["autoReplaceSelection", "runInBackground", "inlineLLM", "appleShortcut", "{{result}}", "%s"] {
            XCTAssertFalse(text.contains(perToolDetail), "\(perToolDetail) belongs in the tool description, read on demand, not in always-resident text")
        }
    }

    // MARK: - House copy rules

    func testNoEmDashes() {
        XCTAssertFalse(text.contains("—"), "no em-dashes in text we ship")
    }

    func testNoSmartQuotesToSurviveJSONAndTerminals() {
        for curly in ["\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}"] {
            XCTAssertFalse(text.contains(curly), "straight quotes only; this text crosses JSON-RPC into unknown terminals")
        }
    }
}
