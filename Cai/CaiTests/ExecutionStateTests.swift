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

    /// A fixed run id, so tests can report a result "for" the run they started.
    private let runA = UUID()
    private let runB = UUID()

    private func start(_ name: String, _ id: UUID) -> ExecutionState.Event {
        .start(name: name, id: id)
    }

    func testStartAndFinishLifecycle() {
        var s = run([start("Digest", runA)])
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
        let s = run([start("A", runA), .finish, .finish, .finish])
        XCTAssertEqual(s.depth, 0)
        XCTAssertFalse(s.isRunning)
    }

    func testNestingKeepsOuterIdentityAndDefersCompletion() {
        // A chain running inside an already-running action deepens the count,
        // keeps the OUTER name, and stays running until the outermost finish.
        var s = run([start("A", runA), start("inner", runB)])
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
        let s = run([start("Chain", runA), .advance(Step(index: 2, total: 3, label: "Summarizing"))])
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
        var s = run([start("outer", runA), start("inner", runB), .reportFailure("boom")])
        s = S.reduce(s, .finish)      // inner ends — still running, nothing published
        XCTAssertNil(s.lastOutcome)
        s = S.reduce(s, .finish)      // outer ends — failure committed
        XCTAssertEqual(s.lastOutcome, .failed("boom"))
    }

    /// The default sink's commit rules, as one table. These are the non-obvious
    /// ones: run identity rejecting a late report, which nesting level's output
    /// survives, that a failure discards a result reported before it, and that
    /// an uncollected result is NOT destroyed by the next run.
    func testResultCommitRules() {
        let sink = "the answer"
        let inner = "inner answer"

        let cases: [(name: String, events: [ExecutionState.Event],
                     newest: String?, unviewed: Int)] = [
            ("no result reported → nothing to collect",
             [start("A", runA), .finish], nil, 0),

            ("reported result commits at the outermost finish",
             [start("A", runA), .produceResult(text: sink, runId: runA), .finish], sink, 1),

            ("result is pending until the outermost finish",
             [start("A", runA), .produceResult(text: sink, runId: runA)], nil, 0),

            // THE REGRESSION: a paste-back completion resolves on a later
            // runloop turn, after the deferred finish() already committed. It
            // used to mutate the idle snapshot and vanish — or, worse, land on
            // whatever run had started since. It must be rejected outright.
            ("a report arriving AFTER its run finished is dropped",
             [start("A", runA), .finish, .produceResult(text: sink, runId: runA)], nil, 0),

            ("a stale report cannot contaminate the run that is live now",
             [start("A", runA), .finish, start("B", runB),
              .produceResult(text: sink, runId: runA), .finish], nil, 0),

            ("nested report wins — it ran last",
             [start("A", runA), start("inner", runB),
              .produceResult(text: inner, runId: runA), .finish, .finish], inner, 1),

            ("a failure discards a result reported before it",
             [start("A", runA), .produceResult(text: sink, runId: runA),
              .reportFailure("boom"), .finish], nil, 0),

            ("a result reported after a failure cannot un-fail the run",
             [start("A", runA), .reportFailure("boom"),
              .produceResult(text: sink, runId: runA), .finish], nil, 0),

            ("viewing clears the pill but keeps the result",
             [start("A", runA), .produceResult(text: sink, runId: runA), .finish,
              .viewResult(id: runA)], sink, 0),

            // The one-slot behaviour this replaced: run B used to destroy A's
            // uncollected output before the user could reach it.
            ("an uncollected result survives the next run",
             [start("A", runA), .produceResult(text: sink, runId: runA), .finish,
              start("B", runB), .produceResult(text: inner, runId: runB), .finish],
             inner, 2),
        ]

        for c in cases {
            let s = run(c.events)
            XCTAssertEqual(s.recent.first?.text, c.newest, c.name)
            XCTAssertEqual(s.unviewedCount, c.unviewed, c.name)
        }
    }

    func testRingCapsAtMaxRecent() {
        // Oldest out first, so a long unattended session can't grow unbounded.
        var s = Snapshot()
        for i in 0..<(ExecutionState.maxRecent + 3) {
            let id = UUID()
            s = S.reduce(s, .start(name: "run\(i)", id: id))
            s = S.reduce(s, .produceResult(text: "out\(i)", runId: id))
            s = S.reduce(s, .finish)
        }
        XCTAssertEqual(s.recent.count, ExecutionState.maxRecent)
        XCTAssertEqual(s.recent.first?.text, "out\(ExecutionState.maxRecent + 2)", "newest first")
    }

    func testNewRunClearsPriorOutcome() {
        // A stale failure must not linger into the next run's progress view.
        var s = run([start("A", runA), .reportFailure("old"), .finish])
        XCTAssertEqual(s.lastOutcome, .failed("old"))
        s = S.reduce(s, start("B", runB))
        XCTAssertNil(s.lastOutcome)
        XCTAssertTrue(s.isRunning)
    }
}
