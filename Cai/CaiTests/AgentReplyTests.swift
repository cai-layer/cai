import CaiActionCore
import XCTest

/// What an agent reads back from Cai.
///
/// These strings are the agent's only view of the app's state, so they are
/// tested for the things an agent has to act on: ids it can pass back, names a
/// chain step can use, and whether a proposal has actually taken effect.
final class AgentReplyTests: XCTestCase {

    private func snapshot(
        actions: [ActionSnapshot] = [CoreFixture.snapshot()],
        enabled: Bool = true
    ) -> ActionsSnapshot {
        ActionsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            actions: actions,
            destinations: [DestinationSummary(name: "Slack", kind: .webhook)],
            builtInActionNames: ["Summarize"],
            agentAuthoringEnabled: enabled
        )
    }

    // MARK: - list_actions

    func testListingCarriesTheIdAnUpdateNeeds() {
        let text = AgentReply.actionsListing(snapshot: snapshot(), statuses: [])

        XCTAssertTrue(
            text.contains("id=\(CoreFixture.targetId.uuidString)"),
            "Without the id an agent cannot call update_action at all: \(text)"
        )
    }

    func testListingNamesWhatAChainStepMayReference() {
        let text = AgentReply.actionsListing(snapshot: snapshot(), statuses: [])

        XCTAssertTrue(text.contains("Destinations a chain step can name: Slack"))
        XCTAssertTrue(text.contains("Built-in actions a chain step can name: Summarize"))
    }

    func testListingShowsAChainSoItIsNotProposedTwice() {
        let chained = CoreFixture.snapshot(next: [.action(name: "Slack")])
        let text = AgentReply.actionsListing(snapshot: snapshot(actions: [chained]), statuses: [])

        XCTAssertTrue(text.contains("chain=Slack"), text)
    }

    func testEmptyListSaysSoRatherThanShowingNothing() {
        let text = AgentReply.actionsListing(snapshot: snapshot(actions: []), statuses: [])

        XCTAssertTrue(text.contains("no custom actions yet"), text)
    }

    func testListingReportsRefusalsWithTheirReason() {
        let statuses = [
            ProposalStatus(id: "abc", state: .waitingForApproval, reason: nil),
            ProposalStatus(id: "def", state: .refused, reason: "Unknown field 'autoApprove'."),
        ]
        let text = AgentReply.actionsListing(snapshot: snapshot(), statuses: statuses)

        XCTAssertTrue(text.contains("abc: waiting for approval"), text)
        XCTAssertTrue(text.contains("def: rejected by Cai (Unknown field 'autoApprove'.)"), text)
    }

    func testListingSaysWhenTheUserHasTurnedAuthoringOff() {
        let off = AgentReply.actionsListing(snapshot: snapshot(enabled: false), statuses: [])
        XCTAssertTrue(off.contains("turned off"), off)

        let on = AgentReply.actionsListing(snapshot: snapshot(enabled: true), statuses: [])
        XCTAssertFalse(on.contains("turned off"))
    }

    func testListingClipsAVeryLongPayload() {
        let long = CoreFixture.snapshot(value: CoreFixture.repeating("x", 5_000))
        let text = AgentReply.actionsListing(snapshot: snapshot(actions: [long]), statuses: [])

        XCTAssertLessThan(text.count, 1_000, "A listing must not dump whole payloads into the agent's context.")
        XCTAssertTrue(text.contains("…"))
    }

    // MARK: - Acknowledging a proposal

    private func validated(tier: ApprovalTier, isUpdate: Bool, warnings: [ActionWarning] = []) -> ValidatedChange {
        ValidatedChange(
            changeId: CoreFixture.changeId,
            provenance: CoreFixture.provenance,
            before: isUpdate ? CoreFixture.snapshot() : nil,
            after: CoreFixture.snapshot(),
            changedFields: isUpdate ? [.value] : [],
            warnings: warnings,
            tier: tier,
            escalationReasons: tier == .escalated ? [.runsShellCommands] : []
        )
    }

    func testTheAgentIsToldNothingHasHappenedYet() {
        let text = AgentReply.proposalAccepted(
            validated: validated(tier: .standard, isUpdate: false),
            actionName: "File issue"
        )

        XCTAssertTrue(text.contains("waiting for the user to approve"), text)
        XCTAssertTrue(
            text.contains("Nothing happens until they do"),
            "An agent that thinks the action exists will go on to use it: \(text)"
        )
    }

    func testEscalatedProposalsSayTheUserMustAcknowledgeFirst() {
        let text = AgentReply.proposalAccepted(
            validated: validated(tier: .escalated, isUpdate: false),
            actionName: "File issue"
        )

        XCTAssertTrue(text.contains("acknowledge"), text)
    }

    func testUpdateRepliesNameTheChangedFields() {
        let text = AgentReply.proposalAccepted(
            validated: validated(tier: .standard, isUpdate: true),
            actionName: "Summarize"
        )

        XCTAssertTrue(text.contains("change to \"Summarize\""), text)
        XCTAssertTrue(text.contains("value"), text)
    }

    func testWarningsShownToTheUserAreRepeatedToTheAgent() {
        let text = AgentReply.proposalAccepted(
            validated: validated(tier: .standard, isUpdate: false, warnings: [.duplicateName("File issue")]),
            actionName: "File issue"
        )

        XCTAssertTrue(text.contains("already named"), text)
    }

    func testNoReplyUsesAnEmDash() {
        let samples = [
            AgentReply.actionsListing(snapshot: snapshot(enabled: false), statuses: [
                ProposalStatus(id: "a", state: .refused, reason: "because"),
            ]),
            AgentReply.proposalAccepted(validated: validated(tier: .escalated, isUpdate: true), actionName: "X"),
        ]
        for sample in samples {
            XCTAssertFalse(sample.contains("—"), sample)
        }
    }
}
