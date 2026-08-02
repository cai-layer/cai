import AppKit
import CaiActionCore
import SwiftUI
import XCTest
@testable import Cai

/// Smoke tests that the approval sheet actually lays out.
///
/// `AppDelegate` sizes the review window from the hosting view's `fittingSize`,
/// so a view that measures to zero (or to something enormous) ships as a window
/// with the payload clipped or running off-screen: exactly the failure the
/// payload-first hierarchy exists to prevent. These render the real view
/// offscreen and check the measurement is sane for each tier.
@MainActor
final class ActionReviewViewLayoutTests: XCTestCase {

    private var root: URL!
    private var store: PendingChangeStore!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cai-review-layout-\(UUID().uuidString)")
        CaiSupportPaths.ensureDirectories(in: root)
        store = PendingChangeStore(
            root: root,
            bridge: ActionStoreBridge(knownActions: { KnownActions() }, upsert: { _, _ in }),
            history: ActionHistoryLog(fileURL: CaiSupportPaths.auditLog(in: root))
        )
    }

    override func tearDown() async throws {
        store.stop()
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func queue(_ draft: ActionDraft) throws {
        let id = UUID()
        let change = PendingChange(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            provenance: ActionProvenance(source: .mcp, client: "Claude Code", authoredAt: Date(timeIntervalSince1970: 0)),
            operation: .create(draft)
        )
        let url = CaiSupportPaths.pendingChanges(in: root).appendingPathComponent("\(id.uuidString).json")
        try ActionCoding.encoder.encode(change).write(to: url)
        store.refresh()
    }

    private func measure() -> NSSize {
        let host = NSHostingView(rootView: ActionReviewView(store: store, onClose: {}, onOpenSettings: {}))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testStandardProposalMeasuresToTheDesignWidthAndAUsableHeight() throws {
        try queue(ActionDraft(name: "Summarize errors", type: .prompt, value: "Summarize this stack trace"))
        XCTAssertEqual(store.pending.count, 1)

        let size = measure()
        XCTAssertEqual(size.width, 540, "The sheet is a fixed 540pt per docs/design/DESIGN.md.")
        XCTAssertGreaterThan(size.height, 120)
        XCTAssertLessThan(size.height, 800, "A short prompt must not produce a full-screen sheet.")
    }

    func testEscalatedProposalIsTallerBecauseItCarriesACalloutAndACheckbox() throws {
        try queue(ActionDraft(name: "Summarize errors", type: .prompt, value: "Summarize this stack trace"))
        let standard = measure()

        store.pending.forEach { store.reject($0) }
        try queue(ActionDraft(
            name: "File issue",
            type: .shell,
            value: "gh issue create --title {{result}}",
            runInBackground: true
        ))
        let escalated = measure()

        XCTAssertEqual(store.pending.first?.tier, .escalated)
        XCTAssertGreaterThan(
            escalated.height,
            standard.height,
            "Two callouts and two acknowledgments have to take vertical space."
        )
        XCTAssertLessThan(escalated.height, 900)
    }

    func testAVeryLongPayloadStaysWithinABoundedWindow() throws {
        try queue(ActionDraft(
            name: "Long one",
            type: .shell,
            value: (1...400).map { "echo line \($0)" }.joined(separator: "\n")
        ))

        let size = measure()
        XCTAssertLessThan(
            size.height,
            900,
            "The payload block scrolls; a 400-line command must not size the window past the screen."
        )
    }

    // MARK: - Window geometry

    /// AppKit origins are bottom-left, so "grow downward, keep the header
    /// still" is the case that silently walks the window off the screen if the
    /// sign is wrong.
    func testWindowKeepsItsTopEdgeWhileTheQueueAdvances() throws {
        let current = NSRect(x: 100, y: 400, width: 540, height: 300)
        let topEdge = current.maxY

        let taller = try XCTUnwrap(AppDelegate.reviewWindowFrame(current: current, contentHeight: 500))
        XCTAssertEqual(taller.maxY, topEdge, accuracy: 0.01, "The header must not move when the sheet grows.")
        XCTAssertEqual(taller.height, 500)
        XCTAssertEqual(taller.origin.x, 100)

        let shorter = try XCTUnwrap(AppDelegate.reviewWindowFrame(current: current, contentHeight: 180))
        XCTAssertEqual(shorter.maxY, topEdge, accuracy: 0.01, "The header must not move when the sheet shrinks.")
        XCTAssertEqual(shorter.height, 180)
    }

    func testWindowWidthIsPinnedAndHeightHasAFloor() throws {
        let current = NSRect(x: 0, y: 0, width: 320, height: 300)

        let frame = try XCTUnwrap(AppDelegate.reviewWindowFrame(current: current, contentHeight: 10))
        XCTAssertEqual(frame.width, 540, "A stray measurement must not narrow the sheet below the design width.")
        XCTAssertEqual(frame.height, 120, "The empty state still needs a window worth looking at.")
    }

    func testNoResizeWhenTheHeightIsAlreadyRight() {
        let current = NSRect(x: 0, y: 0, width: 540, height: 300)
        XCTAssertNil(AppDelegate.reviewWindowFrame(current: current, contentHeight: 300))
        XCTAssertNil(AppDelegate.reviewWindowFrame(current: current, contentHeight: 300.4))
    }

    func testEmptyQueueRendersTheZeroPendingState() {
        XCTAssertTrue(store.pending.isEmpty)

        let size = measure()
        XCTAssertEqual(size.width, 540)
        XCTAssertGreaterThan(size.height, 80)
    }
}
