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
        XCTAssertEqual(s.lastOutcome, .succeeded(nil))   // clean run, nothing kept
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

    /// The default sink's commit rules, as one table. These are the non-obvious
    /// ones: which nesting level's result survives, that a failure discards a
    /// result reported before it, and when the pill should still be advertising.
    func testResultCommitRules() {
        let sink = "the answer"
        let inner = "inner answer"

        let cases: [(name: String, events: [ExecutionState.Event],
                     result: String?, unviewed: Bool)] = [
            ("no result reported → nothing to collect",
             [.start(name: "A"), .finish], nil, false),

            ("reported result commits at the outermost finish",
             [.start(name: "A"), .produceResult(sink), .finish], sink, true),

            ("result is pending until the outermost finish",
             [.start(name: "A"), .produceResult(sink)], nil, false),

            ("nested report wins — it ran last",
             [.start(name: "A"), .start(name: "inner"), .produceResult(inner),
              .finish, .finish], inner, true),

            ("a failure discards a result reported before it",
             [.start(name: "A"), .produceResult(sink), .reportFailure("boom"), .finish],
             nil, false),

            ("a result reported after a failure cannot un-fail the run",
             [.start(name: "A"), .reportFailure("boom"), .produceResult(sink), .finish],
             nil, false),

            ("viewing clears the pill but keeps the result",
             [.start(name: "A"), .produceResult(sink), .finish, .viewResult], sink, false),

            ("a new run supersedes the previous result",
             [.start(name: "A"), .produceResult(sink), .finish, .start(name: "B")], nil, false),
        ]

        for c in cases {
            let s = run(c.events)
            XCTAssertEqual(s.lastResult, c.result, c.name)
            XCTAssertEqual(s.hasUnviewedResult, c.unviewed, c.name)
        }
    }

    func testRunNameSurvivesCompletionForTheResultSurface() {
        // The run surface is reached from the pill long after the fact, so it
        // must still be able to name the run — `action` clears on finish.
        var s = run([.start(name: "Digest"), .produceResult("text"), .finish])
        XCTAssertNil(s.action)
        XCTAssertEqual(s.lastRunName, "Digest")

        // Including when it failed, which is what titles the failure state.
        s = run([.start(name: "Digest"), .reportFailure("boom"), .finish])
        XCTAssertEqual(s.lastRunName, "Digest")
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
