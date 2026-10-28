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
        let target = try AgentAuthoring.resolve(
            id: input.id, intent: .revise, snapshot: snapshot(),
            pending: [], statuses: [], client: CoreFixture.provenance.client
        )
        let change = try AgentAuthoring.authoredUpdate(
            target: target,
            input: input,
            snapshot: snapshot(),
            provenance: CoreFixture.provenance,
            newChangeId: CoreFixture.changeId,
            now: snapshotDate
        ).change

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
        XCTAssertThrowsError(try AgentAuthoring.resolve(
            id: input.id, intent: .revise, snapshot: snapshot(),
            pending: [], statuses: [], client: CoreFixture.provenance.client
        )) { error in
            XCTAssertEqual(error as? ActionRejection, .unknownTargetAction(id: CoreFixture.otherId.uuidString))
        }
    }

    // MARK: - get_action

    func testActionRefDecodesTheDocumentedShape() throws {
        let ref = try AgentAuthoring.decodeActionRef(
            arguments: Data(#"{"id": "\#(CoreFixture.targetId.uuidString)"}"#.utf8)
        )
        XCTAssertEqual(ref.id, CoreFixture.targetId)
    }

    func testActionRefRejectsAnInventedArgument() {
        XCTAssertThrowsError(try AgentAuthoring.decodeActionRef(
            arguments: Data(#"{"id": "\#(CoreFixture.targetId.uuidString)", "fields": ["value"]}"#.utf8)
        ))
    }

    func testActionLookupFailsWithTheSameWordingAsAnUpdate() {
        XCTAssertThrowsError(try AgentAuthoring.action(id: CoreFixture.otherId, snapshot: snapshot())) { error in
            XCTAssertEqual(error as? ActionRejection, .unknownTargetAction(id: CoreFixture.otherId.uuidString))
        }
    }

    func testActionLookupReturnsTheStoredActionUntouched() throws {
        let found = try AgentAuthoring.action(id: CoreFixture.targetId, snapshot: snapshot())
        XCTAssertEqual(found, snapshot().actions.first)
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
    // MARK: - Resolving an id across the lifecycle (P0)

    /// An agent's id can name an installed action or a proposal it is still
    /// waiting on, and the answer decides whether the user ends up with one
    /// card or two. A wrong answer here either duplicates a proposal (the bug
    /// this exists to kill) or edits the wrong object on an approval surface.
    /// Cross-client handling is a column here rather than its own test: it
    /// only changes which row of this same matrix wins.

    private enum ExpectedTarget: Equatable {
        case installed
        case pendingCreate(UUID)
        case pendingUpdate(UUID)
        case rejection(ActionRejection)
    }

    private func pendingFile(
        _ change: PendingChange,
        modifiedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> PendingProposalFile {
        PendingProposalFile(
            url: URL(fileURLWithPath: "/tmp/\(change.id.uuidString).json"),
            change: change,
            modifiedAt: modifiedAt
        )
    }

    private func change(
        id: UUID,
        client: String?,
        operation: PendingChange.Operation
    ) -> PendingChange {
        PendingChange(
            id: id,
            createdAt: snapshotDate,
            provenance: ActionProvenance(source: .mcp, client: client, authoredAt: snapshotDate),
            operation: operation
        )
    }

    func testResolutionMatrix() {
        let mine = "Claude Code"
        let theirs = "Some other agent"
        let installedId = CoreFixture.targetId
        let draftId = CoreFixture.changeId
        let patchId = CoreFixture.otherId

        let myDraft = pendingFile(change(id: draftId, client: mine, operation: .create(CoreFixture.draft())))
        let theirDraft = pendingFile(change(id: draftId, client: theirs, operation: .create(CoreFixture.draft())))
        let myPatch = pendingFile(change(id: patchId, client: mine, operation: .update(
            ActionUpdate(targetId: installedId, changes: ActionPatch(name: "A"), expected: ActionPatch(name: "Existing action"))
        )))
        let theirPatch = pendingFile(change(id: patchId, client: theirs, operation: .update(
            ActionUpdate(targetId: installedId, changes: ActionPatch(name: "A"), expected: ActionPatch(name: "Existing action"))
        )))

        struct Case {
            let label: String
            let id: UUID
            let intent: AgentAuthoring.Intent
            let pending: [PendingProposalFile]
            let statuses: [ProposalStatus]
            let expected: ExpectedTarget
            let line: UInt
        }

        let cases: [Case] = [
            Case(label: "an installed action, nothing waiting", id: installedId, intent: .revise,
                 pending: [], statuses: [], expected: .installed, line: #line),
            Case(label: "my own waiting create, by the id it will be installed under",
                 id: draftId, intent: .revise, pending: [myDraft], statuses: [],
                 expected: .pendingCreate(draftId), line: #line),
            Case(label: "my own waiting patch, by the action it targets",
                 id: installedId, intent: .revise, pending: [myPatch], statuses: [],
                 expected: .pendingUpdate(patchId), line: #line),
            Case(label: "another agent's waiting create cannot be revised: nothing else the id can mean",
                 id: draftId, intent: .revise, pending: [theirDraft], statuses: [],
                 expected: .rejection(.proposalFromAnotherClient(id: draftId.uuidString, client: theirs)),
                 line: #line),
            Case(label: "another agent's waiting create can still be read",
                 id: draftId, intent: .read, pending: [theirDraft], statuses: [],
                 expected: .pendingCreate(draftId), line: #line),
            Case(label: "another agent's waiting patch falls through to a card of my own, "
                    + "rather than locking me out of the action",
                 id: installedId, intent: .revise, pending: [theirPatch], statuses: [],
                 expected: .installed, line: #line),
            Case(label: "reading agrees: another agent's waiting patch is not described as mine to revise",
                 id: installedId, intent: .read, pending: [theirPatch], statuses: [],
                 expected: .installed, line: #line),
            Case(label: "a proposal the user declined is an answer, not something waiting",
                 id: draftId, intent: .revise, pending: [],
                 statuses: [ProposalStatus(id: draftId.uuidString, state: .declined, reason: "no")],
                 expected: .rejection(.proposalDeclined(id: draftId.uuidString)), line: #line),
            Case(label: "a proposal Cai refused carries its reason back",
                 id: draftId, intent: .revise, pending: [],
                 statuses: [ProposalStatus(id: draftId.uuidString, state: .refused, reason: "The action name is empty.")],
                 expected: .rejection(.proposalRefused(id: draftId.uuidString, reason: "The action name is empty.")),
                 line: #line),
            Case(label: "my own waiting patch, by the proposal id Cai handed back for it",
                 id: patchId, intent: .revise, pending: [myPatch],
                 statuses: [ProposalStatus(id: patchId.uuidString, state: .waitingForApproval, reason: nil)],
                 expected: .pendingUpdate(patchId), line: #line),
            Case(label: "another agent's waiting patch, by its proposal id: refused, nothing else it can mean",
                 id: patchId, intent: .revise, pending: [theirPatch], statuses: [],
                 expected: .rejection(.proposalFromAnotherClient(id: patchId.uuidString, client: theirs)),
                 line: #line),
            Case(label: "an id nothing answers to",
                 id: draftId, intent: .revise, pending: [], statuses: [],
                 expected: .rejection(.unknownTargetAction(id: draftId.uuidString)), line: #line),
        ]

        // Two unnamed clients are not one client: an anonymous draft must not be
        // revisable by whoever else happens to be anonymous.
        let anonymousDraft = pendingFile(change(id: draftId, client: nil, operation: .create(CoreFixture.draft())))
        XCTAssertThrowsError(try AgentAuthoring.resolve(
            id: draftId, intent: .revise, snapshot: snapshot(),
            pending: [anonymousDraft], statuses: [], client: nil
        )) { error in
            XCTAssertEqual(
                error as? ActionRejection,
                .proposalFromAnotherClient(id: draftId.uuidString, client: nil)
            )
        }

        for testCase in cases {
            do {
                let target = try AgentAuthoring.resolve(
                    id: testCase.id,
                    intent: testCase.intent,
                    snapshot: snapshot(),
                    pending: testCase.pending,
                    statuses: testCase.statuses,
                    client: mine
                )
                let actual: ExpectedTarget
                switch target {
                case .installedAction: actual = .installed
                case .pendingCreate(let file): actual = .pendingCreate(file.change.id)
                case .pendingUpdate(let file): actual = .pendingUpdate(file.change.id)
                }
                XCTAssertEqual(actual, testCase.expected, testCase.label, line: testCase.line)
            } catch let rejection as ActionRejection {
                XCTAssertEqual(.rejection(rejection), testCase.expected, testCase.label, line: testCase.line)
            } catch {
                XCTFail("unexpected error for \(testCase.label): \(error)", line: testCase.line)
            }
        }
    }

    func testTheNewestOfSeveralWaitingPatchesWins() throws {
        // Two cards can already target one action. Picking by directory order
        // would make "revise my change" a coin flip.
        let older = pendingFile(
            change(id: CoreFixture.changeId, client: "Claude Code", operation: .update(
                ActionUpdate(targetId: CoreFixture.targetId, changes: ActionPatch(name: "Older"), expected: ActionPatch(name: "Existing action"))
            )),
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = pendingFile(
            change(id: CoreFixture.otherId, client: "Claude Code", operation: .update(
                ActionUpdate(targetId: CoreFixture.targetId, changes: ActionPatch(name: "Newer"), expected: ActionPatch(name: "Existing action"))
            )),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let target = try AgentAuthoring.resolve(
            id: CoreFixture.targetId, intent: .revise, snapshot: snapshot(),
            pending: [older, newer], statuses: [], client: "Claude Code"
        )
        guard case .pendingUpdate(let file) = target else {
            return XCTFail("expected the waiting patch, got \(target)")
        }
        XCTAssertEqual(file.change.id, CoreFixture.otherId)
    }

    // MARK: - A revision replaces the card (P0)

    /// The regression that recreates the shipped bug: if a revision does not
    /// reuse the change id, the pending directory grows a second file and the
    /// user approves two versions of one request.
    func testRevisingAWaitingCreateLeavesExactlyOneFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cai-revision-\(UUID().uuidString)")
        CaiSupportPaths.ensureDirectories(in: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = AgentAuthoring.createProposal(
            draft: CoreFixture.draft(name: "First name"),
            provenance: CoreFixture.provenance,
            id: CoreFixture.changeId,
            now: snapshotDate
        )
        try ProposalWriter.write(original, root: root)

        let pending = PendingProposals.all(root: root)
        XCTAssertEqual(pending.count, 1)

        let target = try AgentAuthoring.resolve(
            id: CoreFixture.changeId, intent: .revise, snapshot: snapshot(),
            pending: pending, statuses: [], client: "Claude Code"
        )
        let revised = try AgentAuthoring.authoredUpdate(
            target: target,
            input: AgentAuthoring.UpdateInput(id: CoreFixture.changeId, changes: ActionPatch(name: "Second name")),
            snapshot: snapshot(),
            provenance: CoreFixture.provenance,
            newChangeId: UUID(),
            now: snapshotDate
        )
        try ProposalWriter.write(revised.change, root: root)

        XCTAssertTrue(revised.isRevision)
        XCTAssertEqual(revised.change.id, CoreFixture.changeId, "A revision keeps the id, so it replaces the file.")
        XCTAssertEqual(ProposalWriter.pendingCount(root: root), 1, "One need, one card.")
        XCTAssertEqual(PendingProposals.all(root: root).first?.change.draft?.name, "Second name")
    }

    func testAFileNamedSomethingOtherThanItsIdIsNotAddressable() throws {
        // The pending directory is writable by any local process. Resolving
        // `A.json` by the id `B` inside it would write the revision to
        // `B.json` and leave `A.json` behind: two cards for one change id.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cai-mismatch-\(UUID().uuidString)")
        CaiSupportPaths.ensureDirectories(in: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let change = AgentAuthoring.createProposal(
            draft: CoreFixture.draft(),
            provenance: CoreFixture.provenance,
            id: CoreFixture.changeId,
            now: snapshotDate
        )
        try ActionCoding.encoder.encode(change).write(
            to: CaiSupportPaths.pendingChanges(in: root).appendingPathComponent("not-the-id.json")
        )

        XCTAssertTrue(PendingProposals.all(root: root).isEmpty)
    }

    // MARK: - Merge semantics (P1)

    /// Two different meanings of "revise", and neither may silently lose what
    /// the user is looking at.
    func testMergeSemantics() throws {
        // A waiting create is a whole object, so the patch is applied over it
        // and untouched fields survive.
        let draftFile = pendingFile(change(
            id: CoreFixture.changeId, client: "Claude Code",
            operation: .create(CoreFixture.draft(name: "Original", value: "Original value"))
        ))
        let createRevision = try AgentAuthoring.authoredUpdate(
            target: .pendingCreate(draftFile),
            input: AgentAuthoring.UpdateInput(id: CoreFixture.changeId, changes: ActionPatch(value: "New value")),
            snapshot: snapshot(),
            provenance: CoreFixture.provenance,
            newChangeId: UUID(),
            now: snapshotDate
        )
        XCTAssertEqual(createRevision.change.draft?.value, "New value")
        XCTAssertEqual(createRevision.change.draft?.name, "Original", "Fields the patch does not touch survive.")
        XCTAssertEqual(createRevision.change.id, CoreFixture.changeId)

        // A waiting patch is replaced wholesale: `update_action` means "this
        // is my change to the action", not "this is a delta against my last
        // delta", and it means the same thing on every call.
        let patchFile = pendingFile(change(
            id: CoreFixture.otherId, client: "Claude Code",
            operation: .update(ActionUpdate(
                targetId: CoreFixture.targetId,
                changes: ActionPatch(name: "Was renaming"),
                expected: ActionPatch(name: "Existing action")
            ))
        ))
        let updateRevision = try AgentAuthoring.authoredUpdate(
            target: .pendingUpdate(patchFile),
            input: AgentAuthoring.UpdateInput(id: CoreFixture.targetId, changes: ActionPatch(value: "Now editing the value")),
            snapshot: snapshot(),
            provenance: CoreFixture.provenance,
            newChangeId: UUID(),
            now: snapshotDate
        )
        XCTAssertEqual(updateRevision.change.update?.changes.fields, [.value],
                       "The earlier patch is replaced, not overlaid.")
        XCTAssertEqual(updateRevision.change.update?.expected.value, "Rewrite this as a professional email",
                       "`expected` is recaptured from the live action, so the anti-clobber check still holds.")
        XCTAssertEqual(updateRevision.change.id, CoreFixture.otherId, "Same card.")

        // Addressed by its proposal id rather than the action's: the target
        // still comes from the file, so the patch lands on the right action.
        let byProposalId = try AgentAuthoring.authoredUpdate(
            target: .pendingUpdate(patchFile),
            input: AgentAuthoring.UpdateInput(id: CoreFixture.otherId, changes: ActionPatch(value: "Now editing the value")),
            snapshot: snapshot(),
            provenance: CoreFixture.provenance,
            newChangeId: UUID(),
            now: snapshotDate
        )
        XCTAssertEqual(byProposalId.change.update?.targetId, CoreFixture.targetId)
        XCTAssertTrue(updateRevision.isRevision)

        // An empty patch is a no-op dressed as a change, on either path.
        XCTAssertThrowsError(try AgentAuthoring.authoredUpdate(
            target: .pendingCreate(draftFile),
            input: AgentAuthoring.UpdateInput(id: CoreFixture.changeId, changes: ActionPatch()),
            snapshot: snapshot(), provenance: CoreFixture.provenance,
            newChangeId: UUID(), now: snapshotDate
        )) { XCTAssertEqual($0 as? ActionRejection, .emptyPatch) }
    }

    // MARK: - Preflight and revisions (P1)

    /// A full queue must not lock an agent out of fixing the very proposal
    /// that is filling it, and must still stop it adding a fifty-first card.
    func testTheQueueFullCheckAppliesToNewCardsOnly() {
        let full = ActionSchema.maxPendingChanges
        let rows: [(label: String, pending: Int, isRevision: Bool, throws: Bool)] = [
            ("a new card on an empty queue", 0, false, false),
            ("a new card on a full queue", full, false, true),
            ("a revision on a full queue", full, true, false),
            ("a revision on an empty queue", 0, true, false),
        ]
        for row in rows {
            let attempt = {
                try AgentAuthoring.preflight(
                    snapshot: self.snapshot(),
                    isCaiRunning: true,
                    pendingCount: row.pending,
                    isRevision: row.isRevision
                )
            }
            if row.throws {
                XCTAssertThrowsError(try attempt(), row.label)
            } else {
                XCTAssertNoThrow(try attempt(), row.label)
            }
        }

        // The kill switch and "Cai is closed" are not queue conditions, so a
        // revision is refused for those exactly like anything else.
        XCTAssertThrowsError(try AgentAuthoring.preflight(
            snapshot: snapshot(enabled: false), isCaiRunning: true,
            pendingCount: 0, isRevision: true
        ))
        XCTAssertThrowsError(try AgentAuthoring.preflightAvailability(
            snapshot: snapshot(), isCaiRunning: false
        ))
    }
}
