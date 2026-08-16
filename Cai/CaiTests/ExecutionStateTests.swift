import XCTest
@testable import Cai

/// The running-state machine behind the in-progress indicator. Lean by design
/// (see "Test economy" in CLAUDE.md): covers the non-obvious behaviour only —
/// the nest-safe counter, the failure-outcome commit, the busy decision, and
/// clamping — not trivial getters.
final class ExecutionStateTests: XCTestCase {

    typealias S = ExecutionState
    typealias Snapshot = ExecutionState.Snapshot
    typealias Step = ExecutionState.StepProgress

    /// Folds a sequence of events from idle and returns the final snapshot.
    private func run(_ events: [ExecutionState.Event]) -> Snapshot {
        events.reduce(Snapshot()) { S.reduce($0, $1) }
    }

    func testStartAndFinishLifecycle() {
        var s = run([.start(name: "Digest")])
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.action?.name, "Digest")
        XCTAssertNil(s.action?.step)

        s = S.reduce(s, .finish)
        XCTAssertFalse(s.isRunning)
        XCTAssertNil(s.action)
        XCTAssertEqual(s.lastOutcome, .succeeded)   // clean run → success
    }

    func testExtraFinishClampsAtZero() {
        // A stray extra finish must not drive depth negative (that would leave
        // `isRunning` wrong and could wedge the busy guard forever).
        let s = run([.start(name: "A"), .finish, .finish, .finish])
        XCTAssertEqual(s.depth, 0)
        XCTAssertFalse(s.isRunning)
    }

    func testNestingKeepsOuterIdentityAndDefersCompletion() {
        // A chain running inside an already-running action deepens the count,
        // keeps the OUTER name, and stays running until the outermost finish.
        var s = run([.start(name: "A"), .start(name: "inner")])
        XCTAssertEqual(s.depth, 2)
        XCTAssertEqual(s.action?.name, "A")

        s = S.reduce(s, .finish)      // inner ends
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.action?.name, "A")

        s = S.reduce(s, .finish)      // outer ends
        XCTAssertFalse(s.isRunning)
        XCTAssertNil(s.action)
    }

    func testStepAdvanceAndCaption() {
        let s = run([.start(name: "Chain"), .advance(Step(index: 2, total: 3, label: "Summarizing"))])
        XCTAssertEqual(s.action?.step, Step(index: 2, total: 3, label: "Summarizing"))

        XCTAssertEqual(S.stepCaption(index: 2, total: 3), "Step 2 of 3")
        XCTAssertEqual(S.stepCaption(index: 5, total: 3), "Step 3 of 3")   // clamps
    }

    func testStartDecision() {
        XCTAssertEqual(S.startDecision(isRunning: false), .start)
        XCTAssertEqual(S.startDecision(isRunning: true), .busy)
    }

    func testFailureRecordedOnlyAtOutermostFinish() {
        // A failure at any nesting level marks the whole run failed, but the
        // outcome isn't published until the outermost run ends.
        var s = run([.start(name: "outer"), .start(name: "inner"), .reportFailure("boom")])
        s = S.reduce(s, .finish)      // inner ends — still running, nothing published
        XCTAssertNil(s.lastOutcome)
        s = S.reduce(s, .finish)      // outer ends — failure committed
        XCTAssertEqual(s.lastOutcome, .failed("boom"))
    }

    func testNewRunClearsPriorOutcome() {
        // A stale failure must not linger into the next run's progress view.
        var s = run([.start(name: "A"), .reportFailure("old"), .finish])
        XCTAssertEqual(s.lastOutcome, .failed("old"))
        s = S.reduce(s, .start(name: "B"))
        XCTAssertNil(s.lastOutcome)
        XCTAssertTrue(s.isRunning)
    }
}
