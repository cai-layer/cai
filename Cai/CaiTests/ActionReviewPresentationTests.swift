import CaiActionCore
import XCTest
@testable import Cai

/// What the approval sheet tells the user, and when Approve is allowed to fire.
///
/// These strings are the security boundary's whole vocabulary: a callout that
/// understates a payload, or an interlock that lets Return through early, is
/// how a flow-state click approves something the user did not read.
final class ActionReviewPresentationTests: XCTestCase {

    // MARK: - Escalation copy

    func testEveryReasonHasACalloutAndAMatchingAcknowledgment() {
        for reason in EscalationReason.allCases {
            let callout = ActionReviewPresentation.callout(for: reason)
            let acknowledgment = ActionReviewPresentation.acknowledgment(for: reason)

            XCTAssertFalse(callout.isEmpty, "\(reason) has no callout")
            XCTAssertTrue(callout.hasSuffix("."), "Callouts are sentences: \(callout)")
            XCTAssertTrue(
                acknowledgment.hasPrefix("I understand this action "),
                "The acknowledgment must restate the claim in the first person: \(acknowledgment)"
            )
            XCTAssertFalse(acknowledgment.hasSuffix("."), "Checkbox labels are not sentences: \(acknowledgment)")
        }
    }

    func testCalloutCopyMatchesTheDesignSpecVerbatim() {
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: .runsShellCommands),
            "This action can run terminal commands on your Mac."
        )
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: .sendsSelectionToURL),
            "This action sends your selected text to the URL shown above."
        )
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: .replacesSelection),
            "This action replaces your selected text without showing a preview."
        )
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: .runsWithoutShowingOutput),
            "This action runs without showing its output."
        )
        XCTAssertEqual(
            ActionReviewPresentation.acknowledgment(for: .runsShellCommands),
            "I understand this action can run terminal commands"
        )
    }

    func testNoUserFacingStringUsesAnEmDash() {
        var strings = [
            ActionReviewPresentation.windowTitle,
            ActionReviewPresentation.emptyState,
            ActionReviewPresentation.emptyStateButton,
            ActionReviewPresentation.approveButton,
            ActionReviewPresentation.rejectButton,
            ActionReviewPresentation.arrivalToast(client: "Claude Code", isUpdate: false),
            ActionReviewPresentation.arrivalToast(client: nil, isUpdate: true),
            ActionReviewPresentation.approvedToast(isUpdate: false),
            ActionReviewPresentation.approvedToast(isUpdate: true),
        ]
        strings += EscalationReason.allCases.map(ActionReviewPresentation.callout)
        strings += EscalationReason.allCases.map(ActionReviewPresentation.acknowledgment)
        strings += ActionField.allCases.map(ActionReviewPresentation.fieldLabel)

        for string in strings {
            XCTAssertFalse(string.contains("—"), "Copy must not use em-dashes: \(string)")
        }
    }

    // MARK: - The approve interlock

    private struct InterlockCase {
        let label: String
        let tier: ApprovalTier
        let reasons: [EscalationReason]
        let acknowledged: Set<EscalationReason>
        let expected: Bool
        let line: UInt
    }

    func testApproveInterlockMatrix() {
        let cases: [InterlockCase] = [
            InterlockCase(
                label: "standard tier needs no acknowledgment",
                tier: .standard, reasons: [], acknowledged: [], expected: true, line: #line
            ),
            InterlockCase(
                label: "escalated with nothing checked stays blocked",
                tier: .escalated, reasons: [.runsShellCommands], acknowledged: [], expected: false, line: #line
            ),
            InterlockCase(
                label: "escalated with its one box checked unblocks",
                tier: .escalated, reasons: [.runsShellCommands], acknowledged: [.runsShellCommands],
                expected: true, line: #line
            ),
            InterlockCase(
                label: "two risks, one acknowledged, still blocked",
                tier: .escalated,
                reasons: [.runsShellCommands, .replacesSelection],
                acknowledged: [.runsShellCommands],
                expected: false, line: #line
            ),
            InterlockCase(
                label: "two risks, both acknowledged",
                tier: .escalated,
                reasons: [.runsShellCommands, .replacesSelection],
                acknowledged: [.runsShellCommands, .replacesSelection],
                expected: true, line: #line
            ),
            InterlockCase(
                label: "acknowledging a risk this action does not carry does not unblock it",
                tier: .escalated,
                reasons: [.runsShellCommands],
                acknowledged: [.runsWithoutShowingOutput],
                expected: false, line: #line
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ActionReviewPresentation.canApprove(
                    tier: testCase.tier,
                    reasons: testCase.reasons,
                    acknowledged: testCase.acknowledged
                ),
                testCase.expected,
                testCase.label,
                line: testCase.line
            )
        }
    }

    // MARK: - Queue counter

    func testQueueCounterOnlyAppearsWhenSomethingIsBehindTheCurrentProposal() {
        XCTAssertNil(ActionReviewPresentation.queueCounter(index: 0, total: 1))
        XCTAssertNil(ActionReviewPresentation.queueCounter(index: 0, total: 0))
        XCTAssertEqual(ActionReviewPresentation.queueCounter(index: 0, total: 3), "1 of 3")
        XCTAssertEqual(ActionReviewPresentation.queueCounter(index: 2, total: 3), "3 of 3")
    }

    // MARK: - Toasts and provenance

    func testArrivalToastNamesTheClientAndFallsBackWhenItIsMissing() {
        XCTAssertEqual(
            ActionReviewPresentation.arrivalToast(client: "Claude Code", isUpdate: false),
            "Claude Code proposed a new action"
        )
        XCTAssertEqual(
            ActionReviewPresentation.arrivalToast(client: nil, isUpdate: false),
            "An agent proposed a new action"
        )
        XCTAssertEqual(
            ActionReviewPresentation.arrivalToast(client: "Cursor", isUpdate: true),
            "Cursor proposed a change to an action"
        )
    }

    func testProvenanceLineReadsAsTodayYesterdayOrADate() throws {
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "UTC")!
        calendar.timeZone = zone
        let locale = Locale(identifier: "en_GB")  // 24-hour, stable across machines
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1, hour: 14, minute: 32
        )))

        XCTAssertEqual(
            ActionReviewPresentation.provenanceLine(
                client: "Claude Code", authoredAt: now, now: now,
                calendar: calendar, locale: locale, timeZone: zone
            ),
            "Proposed by Claude Code · today 14:32"
        )
        XCTAssertEqual(
            ActionReviewPresentation.provenanceLine(
                client: nil, authoredAt: now.addingTimeInterval(-86_400), now: now,
                calendar: calendar, locale: locale, timeZone: zone
            ),
            "Proposed by An agent · yesterday 14:32"
        )
        let older = ActionReviewPresentation.provenanceLine(
            client: "Cursor", authoredAt: now.addingTimeInterval(-86_400 * 5), now: now,
            calendar: calendar, locale: locale, timeZone: zone
        )
        XCTAssertTrue(older.contains("Cursor"), older)
        XCTAssertFalse(older.contains("today"), older)
        XCTAssertFalse(older.contains("yesterday"), older)
    }

    func testProvenanceBadgeOnlyExistsForAuthoredActions() {
        XCTAssertNil(ActionReviewPresentation.provenanceBadge(for: nil))
        XCTAssertEqual(
            ActionReviewPresentation.provenanceBadge(for: ActionProvenance(
                source: .mcp, client: "Claude Code", authoredAt: Date(timeIntervalSince1970: 0)
            )),
            "via Claude Code"
        )
        XCTAssertEqual(
            ActionReviewPresentation.provenanceBadge(for: ActionProvenance(
                source: .mcp, client: nil, authoredAt: Date(timeIntervalSince1970: 0)
            )),
            "via An agent"
        )
    }

    // MARK: - Payload labelling

    func testPayloadIsAnnouncedByWhatItActuallyIs() {
        XCTAssertEqual(ActionReviewPresentation.payloadLabel(for: .shell), "Shell command this action will run")
        XCTAssertEqual(ActionReviewPresentation.payloadLabel(for: .url), "URL this action will open")
        XCTAssertEqual(ActionReviewPresentation.payloadLabel(for: .prompt), "Prompt this action will send")
    }

    // MARK: - Chain expansion

    func testChainStepsResolveWhatEachReferencedNameActuallyIs() {
        let known = KnownActions(
            shortcuts: [ActionSnapshot(id: UUID(), name: "Deploy", type: .shell, value: "./deploy.sh")],
            destinations: [
                DestinationSummary(name: "Slack", kind: .webhook),
                DestinationSummary(name: "Notes", kind: .applescript),
            ],
            builtInActionNames: ["Summarize"]
        )
        let steps: [ChainStep] = [
            .action(name: "Deploy"),
            .action(name: "Slack"),
            .action(name: "Summarize"),
            .action(name: "Ghost"),
            .inlineLLM(directive: "shorten"),
            .appleShortcut(name: "Log it"),
        ]

        let displayed = ActionReviewPresentation.chainSteps(steps, known: known)

        XCTAssertEqual(displayed.map(\.kind), [
            "Shell action",
            "Webhook destination",
            "Built-in action",
            "Not installed",
            "Inline AI step",
            "Apple Shortcut",
        ])
        XCTAssertEqual(displayed.map(\.index), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(displayed.first?.label, "Deploy")
    }

    // MARK: - Update diff

    func testDiffShowsOnlyTheFieldsThePatchTouched() {
        let id = UUID()
        let before = ActionSnapshot(id: id, name: "Old name", type: .prompt, value: "Old value")
        let after = ActionSnapshot(id: id, name: "New name", type: .prompt, value: "Old value")

        let rows = ActionReviewPresentation.diffRows(before: before, after: after, changed: [.name])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "Name")
        XCTAssertEqual(rows[0].before, "Old name")
        XCTAssertEqual(rows[0].after, "New name")
    }

    func testDiffRendersChainsAndFlagsReadably() {
        let id = UUID()
        let before = ActionSnapshot(id: id, name: "X", type: .prompt, value: "v", next: [.action(name: "Notes")])
        let after = ActionSnapshot(
            id: id, name: "X", type: .prompt, value: "v",
            runInBackground: true,
            next: [.action(name: "Notes"), .action(name: "Slack")]
        )

        let rows = ActionReviewPresentation.diffRows(
            before: before, after: after, changed: [.runInBackground, .next]
        )

        XCTAssertEqual(rows.map(\.label), ["Run in background", "Chain"])
        XCTAssertEqual(rows[0].before, "false")
        XCTAssertEqual(rows[0].after, "true")
        XCTAssertEqual(rows[1].before, "Notes")
        XCTAssertEqual(rows[1].after, "Notes → Slack")
    }
}
