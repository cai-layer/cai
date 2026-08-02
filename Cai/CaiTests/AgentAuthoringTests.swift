import CaiActionCore
import XCTest

/// The agent-facing half of authoring: what a tool call is allowed to say,
/// what it becomes, and what the agent is told back.
///
/// This used to live in the `cai-mcp` executable, where nothing could test it.
/// It is the surface an agent actually drives, so it gets the same treatment
/// as the rest of the boundary.
final class AgentAuthoringTests: XCTestCase {

    private let snapshotDate = Date(timeIntervalSince1970: 0)

    private func snapshot(
        actions: [ActionSnapshot] = [CoreFixture.snapshot()],
        enabled: Bool = true
    ) -> ActionsSnapshot {
        ActionsSnapshot(
            generatedAt: snapshotDate,
            actions: actions,
            destinations: [DestinationSummary(name: "Slack", kind: .webhook)],
            builtInActionNames: ["Summarize"],
            agentAuthoringEnabled: enabled
        )
    }

    // MARK: - Preflight

    private struct PreflightCase {
        let label: String
        let enabled: Bool
        let running: Bool
        let pending: Int
        let expected: AgentAuthoring.PreflightFailure?
        let line: UInt
    }

    func testPreflightMatrix() {
        let cases: [PreflightCase] = [
            PreflightCase(label: "all clear", enabled: true, running: true, pending: 0, expected: nil, line: #line),
            PreflightCase(label: "kill switch off", enabled: false, running: true, pending: 0, expected: .authoringDisabled, line: #line),
            PreflightCase(label: "Cai closed", enabled: true, running: false, pending: 0, expected: .caiNotRunning, line: #line),
            PreflightCase(label: "queue full", enabled: true, running: true, pending: 50, expected: .queueFull(max: 50), line: #line),
            PreflightCase(
                label: "the switch is reported before anything else, since it is the user's decision",
                enabled: false, running: false, pending: 99, expected: .authoringDisabled, line: #line
            ),
        ]

        for testCase in cases {
            do {
                try AgentAuthoring.preflight(
                    snapshot: snapshot(enabled: testCase.enabled),
                    isCaiRunning: testCase.running,
                    pendingCount: testCase.pending
                )
                XCTAssertNil(testCase.expected, testCase.label, line: testCase.line)
            } catch let failure as AgentAuthoring.PreflightFailure {
                XCTAssertEqual(failure, testCase.expected, testCase.label, line: testCase.line)
            } catch {
                XCTFail("unexpected error for \(testCase.label): \(error)", line: testCase.line)
            }
        }
    }

    func testEveryPreflightReasonTellsTheAgentWhatToDo() {
        let failures: [AgentAuthoring.PreflightFailure] = [.caiNotRunning, .authoringDisabled, .queueFull(max: 50)]
        for failure in failures {
            XCTAssertFalse(failure.reason.isEmpty)
            XCTAssertFalse(failure.reason.contains("—"), failure.reason)
        }
    }

    // MARK: - Decoding create

    func testCreateDecodesTheDocumentedShape() throws {
        let draft = try AgentAuthoring.decodeCreate(arguments: Data("""
        {"name": "File issue", "type": "shell", "value": "gh issue create", "runInBackground": true}
        """.utf8))

        XCTAssertEqual(draft.name, "File issue")
        XCTAssertEqual(draft.type, .shell)
        XCTAssertTrue(draft.runInBackground)
        XCTAssertFalse(draft.pinned)
    }

    func testCreateRejectsAnInventedArgument() {
        XCTAssertThrowsError(try AgentAuthoring.decodeCreate(arguments: Data("""
        {"name": "X", "type": "prompt", "value": "y", "autoApprove": true}
        """.utf8))) { error in
            XCTAssertEqual(error as? ActionRejection, .unknownField("action.autoApprove"))
        }
    }

    func testCreateNamesTheMissingArgument() {
        XCTAssertThrowsError(try AgentAuthoring.decodeCreate(arguments: Data("""
        {"name": "X", "type": "prompt"}
        """.utf8))) { error in
            guard case .malformedJSON(let detail) = error as? ActionRejection else {
                return XCTFail("expected a malformedJSON rejection, got \(error)")
            }
            XCTAssertTrue(detail.contains("value"), detail)
        }
    }

    func testCreateRejectsAnUnknownType() {
        XCTAssertThrowsError(try AgentAuthoring.decodeCreate(arguments: Data("""
        {"name": "X", "type": "applescript", "value": "beep"}
        """.utf8)))
    }

    // MARK: - Decoding update

    func testUpdateDecodesIdAndChanges() throws {
        let input = try AgentAuthoring.decodeUpdate(arguments: Data("""
        {"id": "22222222-2222-2222-2222-222222222222", "changes": {"name": "Shorter"}}
        """.utf8))

        XCTAssertEqual(input.id, CoreFixture.targetId)
        XCTAssertEqual(input.changes.fields, [.name])
    }

    func testUpdateRefusesAnExpectedBlockFromTheAgent() {
        // `expected` is captured from the snapshot, never supplied: an agent
        // that could set it could defeat the anti-clobber check.
        XCTAssertThrowsError(try AgentAuthoring.decodeUpdate(arguments: Data("""
        {"id": "22222222-2222-2222-2222-222222222222", "changes": {"name": "X"}, "expected": {"name": "Y"}}
        """.utf8))) { error in
            XCTAssertEqual(error as? ActionRejection, .unknownField("expected"))
        }
    }

    // MARK: - Building proposals

    func testUpdateCapturesTheCurrentValuesAsExpected() throws {
        let input = AgentAuthoring.UpdateInput(
            id: CoreFixture.targetId,
            changes: ActionPatch(name: "Shorter name")
        )
        let change = try AgentAuthoring.updateProposal(
            input: input,
            snapshot: snapshot(),
            provenance: CoreFixture.provenance,
            id: CoreFixture.changeId,
            now: snapshotDate
        )

        guard case .update(let update) = change.operation else {
            return XCTFail("expected an update operation")
        }
        XCTAssertEqual(update.changes.name, "Shorter name")
        XCTAssertEqual(
            update.expected.name, "Existing action",
            "The value read from the snapshot is what the app checks against at approval time."
        )
        XCTAssertNil(update.expected.value, "Only the touched fields are captured.")
    }

    func testUpdateAgainstAnUnknownIdFailsBeforeAnythingIsWritten() {
        let input = AgentAuthoring.UpdateInput(id: CoreFixture.otherId, changes: ActionPatch(name: "X"))
        XCTAssertThrowsError(try AgentAuthoring.updateProposal(
            input: input,
            snapshot: snapshot(),
            provenance: CoreFixture.provenance,
            id: CoreFixture.changeId,
            now: snapshotDate
        )) { error in
            XCTAssertEqual(error as? ActionRejection, .unknownTargetAction(id: CoreFixture.otherId.uuidString))
        }
    }

    func testCreateProposalCarriesProvenanceAndTheGivenClock() {
        let change = AgentAuthoring.createProposal(
            draft: CoreFixture.draft(),
            provenance: CoreFixture.provenance,
            id: CoreFixture.changeId,
            now: snapshotDate
        )

        XCTAssertEqual(change.id, CoreFixture.changeId)
        XCTAssertEqual(change.createdAt, snapshotDate)
        XCTAssertEqual(change.provenance.client, "Claude Code")
        XCTAssertEqual(change.schemaVersion, ActionSchema.version)
    }
}
