import CaiActionCore
import XCTest

/// How the filesystem answers "what became of my proposal".
///
/// `ProposalStatus.all` is the only source `list_actions` has, so what it
/// reads out of the pending directory and the quarantine sidecars is what the
/// agent gets to correlate on: the proposal id, what it proposed, and which
/// client sent it.
final class ProposalStatusTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cai-status-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Pending

    func testAPendingCreateCarriesItsActionNameAndClient() throws {
        try ProposalWriter.write(CoreFixture.createChange(), root: root)

        let status = try XCTUnwrap(ProposalStatus.all(root: root).first)
        XCTAssertEqual(status.state, .waitingForApproval)
        XCTAssertEqual(status.label, "File issue")
        XCTAssertEqual(status.client, "Claude Code")
    }

    func testAPendingUpdateNamesTheActionItTargets() throws {
        try ProposalWriter.write(CoreFixture.updateChange(
            changes: ActionPatch(value: "new"),
            expected: ActionPatch(value: "old")
        ), root: root)

        let status = try XCTUnwrap(ProposalStatus.all(root: root).first)
        XCTAssertEqual(
            status.label, "update to action \(CoreFixture.targetId.uuidString)",
            "The target id is the one the agent itself passed to update_action."
        )
    }

    func testAnUnreadablePendingFileStillReportsWithoutALabel() throws {
        let directory = CaiSupportPaths.pendingChanges(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        let status = try XCTUnwrap(ProposalStatus.all(root: root).first)
        XCTAssertEqual(status.id, "broken")
        XCTAssertNil(status.label, "A payload that never decoded has no name to offer.")
    }

    // MARK: - Quarantine sidecars

    func testASidecarPassesItsNameAndClientThrough() throws {
        try writeSidecar(QuarantineRecord(
            rejectedAt: CoreFixture.epoch,
            reason: "The user reviewed this and declined it.",
            outcome: .declined,
            actionName: "File issue",
            client: "Cursor"
        ))

        let status = try XCTUnwrap(ProposalStatus.all(root: root).first)
        XCTAssertEqual(status.state, .declined)
        XCTAssertEqual(status.label, "File issue")
        XCTAssertEqual(status.client, "Cursor")
    }

    /// Sidecars written before these fields existed omit them; they must keep
    /// decoding and simply report without a label.
    func testAnOlderSidecarWithoutTheNewFieldsStillDecodes() throws {
        try writeSidecar(QuarantineRecord(
            rejectedAt: CoreFixture.epoch,
            reason: "Unknown field 'autoApprove'."
        ))

        let status = try XCTUnwrap(ProposalStatus.all(root: root).first)
        XCTAssertEqual(status.state, .refused)
        XCTAssertEqual(status.reason, "Unknown field 'autoApprove'.")
        XCTAssertNil(status.label)
        XCTAssertNil(status.client)
    }

    // MARK: - Untrusted lengths

    /// Pending files are written by any local process and the name is only
    /// length-validated later, at approval time. Left unclamped, a hostile
    /// file would pump megabytes into every connected agent's context.
    func testAGiantNameInAPendingFileIsClampedBeforeItReachesAgents() throws {
        let giant = CoreFixture.repeating("x", 100_000)
        try ProposalWriter.write(
            CoreFixture.createChange(CoreFixture.draft(name: giant)), root: root
        )

        let status = try XCTUnwrap(ProposalStatus.all(root: root).first)
        let label = try XCTUnwrap(status.label)
        XCTAssertLessThan(label.count, 100, "80 characters plus the ellipsis.")
        XCTAssertTrue(label.hasSuffix("…"))
    }

    private func writeSidecar(_ record: QuarantineRecord) throws {
        let directory = CaiSupportPaths.quarantine(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ActionCoding.encoder.encode(record)
            .write(to: directory.appendingPathComponent("\(CoreFixture.changeId.uuidString).rejection.json"))
    }
}
