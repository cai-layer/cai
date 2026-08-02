import CaiActionCore
import XCTest
@testable import Cai

/// The app's half of the handoff to `cai-mcp`: the snapshot it publishes and
/// the symlink an agent's config points at.
@MainActor
final class HelperHandoffTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cai-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Snapshot

    func testPublishedSnapshotIsReadableByTheHelpersDecoder() throws {
        ActionsSnapshotPublisher(root: root).publishNow()

        let url = CaiSupportPaths.actionsSnapshot(in: root)
        let data = try Data(contentsOf: url)
        let snapshot = try ActionCoding.decoder.decode(ActionsSnapshot.self, from: data)

        XCTAssertEqual(snapshot.schemaVersion, ActionSchema.version)
        XCTAssertEqual(
            snapshot.actions.map(\.name),
            CaiSettings.shared.shortcuts.map(\.name),
            "The helper resolves chain steps against this, so it must match what the app has."
        )
    }

    func testSnapshotIsOwnerOnly() throws {
        ActionsSnapshotPublisher(root: root).publishNow()

        let path = CaiSupportPaths.actionsSnapshot(in: root).path
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(
            permissions.int16Value, 0o600,
            "It carries the user's own prompts and commands."
        )
    }

    func testSnapshotCarriesTheKillSwitchSoTheHelperCanExplainItself() throws {
        ActionsSnapshotPublisher(root: root).publishNow()

        let data = try Data(contentsOf: CaiSupportPaths.actionsSnapshot(in: root))
        let snapshot = try ActionCoding.decoder.decode(ActionsSnapshot.self, from: data)

        XCTAssertEqual(snapshot.agentAuthoringEnabled, CaiSettings.shared.allowAgentProposals)
    }

    func testSnapshotRoundTripsIntoTheSameKnownActionsTheValidatorUses() throws {
        ActionsSnapshotPublisher(root: root).publishNow()

        let data = try Data(contentsOf: CaiSupportPaths.actionsSnapshot(in: root))
        let snapshot = try ActionCoding.decoder.decode(ActionsSnapshot.self, from: data)

        XCTAssertEqual(snapshot.knownActions, CaiSettings.shared.knownActions)
    }

    // MARK: - Symlink

    func testSymlinkIsLeftAloneWhenItAlreadyPointsAtThisBundle() {
        XCTAssertFalse(
            HelperInstaller.needsRefresh(
                currentDestination: "/Applications/Cai.app/Contents/Helpers/cai-mcp",
                desiredPath: "/Applications/Cai.app/Contents/Helpers/cai-mcp"
            ),
            "Relinking every launch opens a window where an agent finds nothing there."
        )
    }

    func testSymlinkIsRewrittenWhenTheAppHasMovedOrIsMissing() {
        XCTAssertTrue(HelperInstaller.needsRefresh(
            currentDestination: "/Users/someone/Downloads/Cai.app/Contents/Helpers/cai-mcp",
            desiredPath: "/Applications/Cai.app/Contents/Helpers/cai-mcp"
        ))
        XCTAssertTrue(
            HelperInstaller.needsRefresh(currentDestination: nil, desiredPath: "/Applications/Cai.app/Contents/Helpers/cai-mcp"),
            "No link yet is the first-launch case."
        )
    }

    /// The test host IS Cai.app, so this exercises the real embedded helper.
    func testSymlinkPointsAtTheHelperInsideThisBundle() throws {
        XCTAssertTrue(HelperInstaller.refreshSymlink(bundle: .main, root: root))

        let link = CaiSupportPaths.helperSymlink(in: root)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)

        XCTAssertEqual(destination, HelperInstaller.bundledHelper(in: .main).path)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: destination),
            "The link has to resolve to something an agent can actually spawn."
        )
    }

    func testInstallerRefusesToLinkWhenNoHelperIsEmbedded() {
        // A bundle that is not Cai.app and therefore has no Contents/Helpers.
        let helperless = Bundle(for: XCTestCase.self)

        XCTAssertFalse(
            HelperInstaller.refreshSymlink(bundle: helperless, root: root),
            "A dangling link is worse than none: the agent would get a spawn failure with no explanation."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: CaiSupportPaths.helperSymlink(in: root).path)
        )
    }

    func testBundledHelperPathMatchesTheEmbedPhase() {
        let bundle = Bundle(for: type(of: self))
        let path = HelperInstaller.bundledHelper(in: bundle).path
        XCTAssertTrue(
            path.hasSuffix("/Contents/Helpers/cai-mcp"),
            "This must stay in step with the Embed Helpers copy phase: \(path)"
        )
    }
}
