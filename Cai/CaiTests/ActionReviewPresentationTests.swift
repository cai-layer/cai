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

    func testEveryReasonHasACallout() {
        for reason in EscalationReason.allCases {
            let callout = ActionReviewPresentation.callout(for: reason)
            XCTAssertFalse(callout.isEmpty, "\(reason) has no callout")
            XCTAssertTrue(callout.hasSuffix("."), "Callouts are sentences: \(callout)")
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
        // Not in the design spec's original four: added when unresolved chain
        // names started escalating, because a name no one has claimed yet can
        // be claimed by a later shell action.
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: .chainsToUnknownAction),
            "This action triggers another action that doesn't exist yet, so Cai can't say what it will do."
        )
    }

    // MARK: - Secrets callout

    func testTheSecretsCalloutNamesWhatThePayloadReachesFor() {
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: .referencesSecrets, secretNames: ["NOTION_API_TOKEN"]),
            "This action uses your secret NOTION_API_TOKEN."
        )
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: .referencesSecrets, secretNames: ["B_TOKEN", "A_TOKEN"]),
            "This action uses your secrets A_TOKEN and B_TOKEN."
        )
    }

    func testTheSecretsCalloutWithoutNamesStillWarns() {
        // A chained action can carry the reason while the proposal's own text
        // has no reference; generic beats silent.
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: .referencesSecrets),
            "This action uses one of your secrets."
        )
        XCTAssertEqual(
            ActionReviewPresentation.calloutBullet(for: .referencesSecrets),
            "Use one of your secrets"
        )
    }

    func testSecretListFormatting() {
        XCTAssertEqual(ActionReviewPresentation.secretList(["A"]), "A")
        XCTAssertEqual(ActionReviewPresentation.secretList(["B", "A"]), "A and B")
        XCTAssertEqual(ActionReviewPresentation.secretList(["C", "A", "B"]), "A, B and C")
    }

    func testSecretNamesOnlyChangeTheSecretsCallout() {
        // Passing names must not perturb the other reasons' verbatim copy.
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: .runsShellCommands, secretNames: ["NOTION_API_TOKEN"]),
            "This action can run terminal commands on your Mac."
        )
    }

    // MARK: - Grouped callout

    func testOneRiskKeepsTheSpecsSentence() {
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: [.runsShellCommands]),
            .sentence("This action can run terminal commands on your Mac.")
        )
    }

    func testSeveralRisksCollapseIntoOneHeadedList() {
        XCTAssertEqual(
            ActionReviewPresentation.callout(for: [.runsShellCommands, .runsWithoutShowingOutput]),
            .grouped(
                header: "This action will:",
                bullets: ["Run terminal commands on your Mac", "Run without showing its output"]
            )
        )
    }

    func testNoRisksRenderNoCallout() {
        XCTAssertEqual(ActionReviewPresentation.callout(for: []), .none)
    }

    func testBulletsCoverEveryRiskAndReadAsListItems() {
        for reason in EscalationReason.allCases {
            let bullet = ActionReviewPresentation.calloutBullet(for: reason)
            XCTAssertFalse(bullet.isEmpty, "\(reason) has no bullet")
            XCTAssertFalse(bullet.hasSuffix("."), "List items are not sentences: \(bullet)")
            XCTAssertFalse(
                bullet.hasPrefix("This action"),
                "The header already says it: \(bullet)"
            )
        }
    }

    func testNoUserFacingStringUsesAnEmDash() {
        var strings = [
            ActionReviewPresentation.windowTitle(name: "Unread mail digest", isUpdate: false).combined,
            ActionReviewPresentation.windowTitle(name: "Unread mail digest", isUpdate: true).combined,
            ActionReviewPresentation.emptyState,
            ActionReviewPresentation.emptyStateButton,
            ActionReviewPresentation.approveButton,
            ActionReviewPresentation.rejectButton,
            ActionReviewPresentation.arrivalToast(client: "Claude Code", isUpdate: false),
            ActionReviewPresentation.arrivalToast(client: nil, isUpdate: true),
            ActionReviewPresentation.approvedToast(isUpdate: false),
            ActionReviewPresentation.approvedToast(isUpdate: true),
        ]
        strings += EscalationReason.allCases.map { ActionReviewPresentation.callout(for: $0) }
        strings.append(ActionReviewPresentation.acknowledgmentLabel)
        strings += ActionField.allCases.map(ActionReviewPresentation.fieldLabel)
        strings.append(ActionReviewPresentation.showLessPayload)
        strings.append(ActionReviewPresentation.showMorePayload(totalLines: 142))
        strings += CaiActionType.allCases.map {
            ActionReviewPresentation.actionSummary(
                type: $0,
                steps: [.inlineLLM(directive: "x"), .action(name: "y")],
                known: KnownActions(shortcuts: [], destinations: [], builtInActionNames: [])
            )
        }

        for string in strings {
            XCTAssertFalse(string.contains("—"), "Copy must not use em-dashes: \(string)")
        }
    }

    // MARK: - Window title

    func testTitleNamesTheActionAndWhetherItIsNewOrAChange() {
        let create = ActionReviewPresentation.windowTitle(name: "Unread mail digest", isUpdate: false)
        XCTAssertEqual(create.prefix, "New action")
        XCTAssertEqual(create.name, "Unread mail digest")
        XCTAssertEqual(create.combined, "New action · Unread mail digest")

        let update = ActionReviewPresentation.windowTitle(name: "Unread mail digest", isUpdate: true)
        XCTAssertEqual(update.prefix, "Update")
        XCTAssertEqual(update.name, "Unread mail digest")
        XCTAssertEqual(update.combined, "Update · Unread mail digest")
    }

    func testTitleNameIsSanitizedToASingleCappedLine() {
        // The name is attacker-controlled. A newline would fake a second title
        // line; an over-long name would run past the sheet. Both are neutralized
        // here rather than trusted from upstream.
        let sneaky = ActionReviewPresentation.windowTitle(
            name: "line one\nrm -rf ~", isUpdate: false
        )
        XCTAssertFalse(sneaky.name.contains("\n"), "A name cannot introduce a second line.")
        XCTAssertEqual(sneaky.name, "line onerm -rf ~")

        let long = ActionReviewPresentation.windowTitle(
            name: String(repeating: "A", count: 500), isUpdate: true
        )
        XCTAssertLessThanOrEqual(long.name.count, ActionSchema.maxNameLength)
    }

    // MARK: - Body scroll cap

    func testBodyMaxHeightTargetsEightyPercentButKeepsRoomForThePinnedControls() {
        // Very large display: the 80% target wins and the payload gets the most
        // room, because reserving a fixed chrome band leaves more than 80% free.
        XCTAssertEqual(ActionReviewPresentation.bodyMaxHeight(screenHeight: 2000), 1600, accuracy: 0.5)

        // Typical / short displays: the reserved chrome floor wins, so the
        // pinned Approve button can never be pushed below the screen even though
        // that means the scroll gets a little less than 80%.
        XCTAssertEqual(ActionReviewPresentation.bodyMaxHeight(screenHeight: 1500), 1160, accuracy: 0.5)
        XCTAssertEqual(ActionReviewPresentation.bodyMaxHeight(screenHeight: 800), 460, accuracy: 0.5)

        // Never collapse to a sliver, whatever a stray tiny measurement says.
        XCTAssertEqual(ActionReviewPresentation.bodyMaxHeight(screenHeight: 100), 240, accuracy: 0.5)
    }

    // MARK: - The approve interlock

    func testApproveNeedsTheAcknowledgmentOnlyOnTheEscalatedTier() {
        XCTAssertTrue(ActionReviewPresentation.canApprove(tier: .standard, acknowledged: false))
        XCTAssertTrue(ActionReviewPresentation.canApprove(tier: .standard, acknowledged: true))
        XCTAssertFalse(
            ActionReviewPresentation.canApprove(tier: .escalated, acknowledged: false),
            "An escalated proposal must not be approvable on one click."
        )
        XCTAssertTrue(ActionReviewPresentation.canApprove(tier: .escalated, acknowledged: true))
    }

    func testTheAcknowledgmentRefersToTheCalloutRatherThanRestatingIt() {
        // "This action can run terminal commands on your Mac." directly above
        // "I understand this action can run terminal commands" is the same
        // sentence twice, which costs height and teaches the eye to skip it.
        let label = ActionReviewPresentation.acknowledgment(for: [.runsShellCommands])

        XCTAssertEqual(label, "I understand what this action can do")
        XCTAssertFalse(
            label?.contains("terminal") ?? true,
            "The risk is stated in the callout; the checkbox points at it."
        )
    }

    func testTheAcknowledgmentIsTheSameWhateverTheRisks() {
        // One box, one wording. The callout carries the specifics, so the label
        // does not grow a clause per risk.
        XCTAssertEqual(
            ActionReviewPresentation.acknowledgment(for: [.runsShellCommands]),
            ActionReviewPresentation.acknowledgment(
                for: [.runsShellCommands, .sendsSelectionToURL, .runsWithoutShowingOutput]
            )
        )
    }

    func testNoRisksNeedNoAcknowledgment() {
        XCTAssertNil(
            ActionReviewPresentation.acknowledgment(for: []),
            "No callout, so nothing for a checkbox to point at."
        )
    }

    // MARK: - Queue counter

    func testQueueCounterOnlyAppearsWhenSomethingIsBehindTheCurrentProposal() {
        XCTAssertNil(ActionReviewPresentation.queueCounter(index: 0, total: 1))
        XCTAssertNil(ActionReviewPresentation.queueCounter(index: 0, total: 0))
        XCTAssertEqual(ActionReviewPresentation.queueCounter(index: 0, total: 3), "1 of 3")
        XCTAssertEqual(ActionReviewPresentation.queueCounter(index: 2, total: 3), "3 of 3")
    }

    // MARK: - Browsing the queue

    func testTheBrowsePositionStaysInsideALiveQueue() {
        // Deciding the last of three leaves the index past the end; unclamped,
        // the sheet renders nothing at all.
        XCTAssertEqual(ActionReviewPresentation.clampedQueueIndex(2, count: 2), 1)
        XCTAssertEqual(ActionReviewPresentation.clampedQueueIndex(5, count: 3), 2)
        XCTAssertEqual(ActionReviewPresentation.clampedQueueIndex(-1, count: 3), 0)
        XCTAssertEqual(ActionReviewPresentation.clampedQueueIndex(1, count: 3), 1)
    }

    func testAnEmptyQueueClampsToZeroRatherThanCrashing() {
        XCTAssertEqual(ActionReviewPresentation.clampedQueueIndex(4, count: 0), 0)
    }

    func testTheCounterFollowsTheBrowsePosition() {
        XCTAssertEqual(ActionReviewPresentation.queueCounter(index: 1, total: 3), "2 of 3")
        XCTAssertNil(
            ActionReviewPresentation.queueCounter(index: 0, total: 1),
            "One proposal needs no position indicator, and no chevrons to go with it."
        )
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
            ActionReviewPresentation.provenanceSubtitle(
                client: "Claude Code", authoredAt: now, now: now,
                calendar: calendar, locale: locale, timeZone: zone
            ),
            "Claude Code · today 14:32"
        )
        XCTAssertEqual(
            ActionReviewPresentation.provenanceSubtitle(
                client: nil, authoredAt: now.addingTimeInterval(-86_400), now: now,
                calendar: calendar, locale: locale, timeZone: zone
            ),
            "An agent · yesterday 14:32"
        )
        let older = ActionReviewPresentation.provenanceSubtitle(
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

    // MARK: - Action summary

    func testSummaryDescribesTheMechanismInCaisOwnVoice() {
        let known = KnownActions(
            shortcuts: [],
            destinations: [DestinationSummary(name: "Slack", kind: .webhook)],
            builtInActionNames: []
        )
        // No chain: just the base clause.
        XCTAssertEqual(
            ActionReviewPresentation.actionSummary(type: .shell, steps: [], known: known),
            "Runs a shell command."
        )
        XCTAssertEqual(
            ActionReviewPresentation.actionSummary(type: .prompt, steps: [], known: known),
            "Sends a prompt to your model."
        )
        // The prompt engine folds into the clause (privacy-relevant: on-device
        // vs a cloud provider), so the sheet needs no separate "Runs with" line.
        XCTAssertEqual(
            ActionReviewPresentation.actionSummary(
                type: .prompt, steps: [], known: known, promptModel: "Built-in"
            ),
            "Sends a prompt to the Built-in model."
        )
        // Chained: the mechanism reads left to right, destinations resolved.
        XCTAssertEqual(
            ActionReviewPresentation.actionSummary(
                type: .prompt,
                steps: [.inlineLLM(directive: "shorten"), .action(name: "Slack")],
                known: known
            ),
            "Sends a prompt to your model, then runs an AI step, then sends to a webhook."
        )
    }

    func testSummaryNeverBorrowsTheAgentsWords() {
        // The summary is built from type + chain only. An attacker-named step
        // contributes its resolved KIND, never its name, so the sentence cannot
        // be made to assert anything the sheet has not verified.
        let known = KnownActions(shortcuts: [], destinations: [], builtInActionNames: [])
        let summary = ActionReviewPresentation.actionSummary(
            type: .shell,
            steps: [.action(name: "totally safe, just formats text")],
            known: known
        )
        XCTAssertFalse(summary.contains("just formats text"), summary)
        XCTAssertEqual(summary, "Runs a shell command, then triggers an action that isn't installed yet.")
    }

    // MARK: - Payload folding

    func testOnlyLongRisklessPromptPayloadsFold() {
        let long = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let short = "one line"

        // Prompt, long, no risk: folds, and reports the true line count.
        let folded = ActionReviewPresentation.collapsedPayload(type: .prompt, value: long, hasRisks: false)
        XCTAssertEqual(folded?.lineLimit, ActionReviewPresentation.payloadFoldThreshold)
        XCTAssertEqual(folded?.totalLines, 30)

        // Prompt, short: nothing to fold.
        XCTAssertNil(ActionReviewPresentation.collapsedPayload(type: .prompt, value: short, hasRisks: false))

        // Executable evidence never folds, however long.
        XCTAssertNil(ActionReviewPresentation.collapsedPayload(type: .shell, value: long, hasRisks: false))
        XCTAssertNil(ActionReviewPresentation.collapsedPayload(type: .url, value: long, hasRisks: false))

        // A risk-flagged prompt auto-expands: its evidence is never behind a fold.
        XCTAssertNil(ActionReviewPresentation.collapsedPayload(type: .prompt, value: long, hasRisks: true))
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
