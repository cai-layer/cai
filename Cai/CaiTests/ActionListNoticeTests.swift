import XCTest
@testable import Cai

/// Which of the three competing notices the action list shows.
///
/// This used to be a chain of negations inside the view, where adding a third
/// notice meant remembering to negate it in the other two. Table-driven so the
/// order is stated once and stays stated.
final class ActionListNoticeTests: XCTestCase {

    private struct NoticeCase {
        let label: String
        let pendingProposals: Int
        let updateAvailable: Bool
        let crashPromptShown: Bool
        let expected: ActionListNotice?
        let line: UInt
    }

    func testPriorityMatrix() {
        let cases: [NoticeCase] = [
            NoticeCase(
                label: "nothing to say",
                pendingProposals: 0, updateAvailable: false, crashPromptShown: true,
                expected: nil, line: #line
            ),
            NoticeCase(
                label: "only the crash prompt",
                pendingProposals: 0, updateAvailable: false, crashPromptShown: false,
                expected: .crashReporting, line: #line
            ),
            NoticeCase(
                label: "an update outranks the crash prompt",
                pendingProposals: 0, updateAvailable: true, crashPromptShown: false,
                expected: .update, line: #line
            ),
            NoticeCase(
                label: "a proposal outranks an update",
                pendingProposals: 1, updateAvailable: true, crashPromptShown: false,
                expected: .proposals(count: 1), line: #line
            ),
            NoticeCase(
                label: "several proposals carry their count",
                pendingProposals: 3, updateAvailable: false, crashPromptShown: true,
                expected: .proposals(count: 3), line: #line
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ActionListNotice.active(
                    pendingProposals: testCase.pendingProposals,
                    updateAvailable: testCase.updateAvailable,
                    crashPromptShown: testCase.crashPromptShown
                ),
                testCase.expected,
                testCase.label,
                line: testCase.line
            )
        }
    }

    func testProposalCopyIsSingularForOne() {
        XCTAssertEqual(ActionListNotice.proposals(count: 1).message, "1 proposed action waiting")
        XCTAssertEqual(ActionListNotice.proposals(count: 4).message, "4 proposed actions waiting")
    }

    func testOnlyTheCrashPromptCanBeDeclinedFromTheBanner() {
        XCTAssertNil(ActionListNotice.proposals(count: 1).declineTitle)
        XCTAssertNil(ActionListNotice.update.declineTitle)
        XCTAssertEqual(ActionListNotice.crashReporting.declineTitle, "Nope")
    }

    func testNoNoticeCopyUsesAnEmDash() {
        let notices: [ActionListNotice] = [.proposals(count: 1), .proposals(count: 2), .update, .crashReporting]
        for notice in notices {
            XCTAssertFalse(notice.message.contains("—"), notice.message)
            XCTAssertFalse(notice.actionTitle.contains("—"), notice.actionTitle)
        }
    }
}
