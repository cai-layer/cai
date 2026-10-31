import XCTest
@testable import Cai

/// The running-state machine behind the in-progress indicator. Lean by design
/// (see "Test economy" in CLAUDE.md): covers the non-obvious behaviour only —
/// the nest-safe counter, the failure-outcome commit, the queue's line order, and
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

    // MARK: - (P1) Queue line order

    /// Locks down: FIFO order, the head consumed when it starts with its own
    /// id (and marked `waited`, which turns paste-back into a copy), an
    /// unqueued start not taking a waiting item's seat, and a nested start
    /// leaving the line alone.
    func testQueueLineOrder() {
        let a = S.QueuedRun(id: UUID(), name: "A")
        let b = S.QueuedRun(id: UUID(), name: "B")
        let other = UUID()
        let cases: [(name: String, events: [S.Event], queued: [S.QueuedRun], running: String?, waited: Bool?)] = [
            ("head starts: consumed, waited", [.enqueue(a), .enqueue(b), start("A", a.id)], [b], "A", true),
            ("unqueued start leaves the line", [.enqueue(a), .enqueue(b), start("C", other)], [a, b], "C", false),
            ("non-head id starting doesn't jump the line", [.enqueue(a), .enqueue(b), start("B", b.id)], [a, b], "B", false),
            ("nested start leaves the line", [start("C", other), .enqueue(a), start("inner", a.id)], [a], "C", false),
        ]
        for c in cases {
            let s = run(c.events)
            XCTAssertEqual(s.queued, c.queued, c.name)
            XCTAssertEqual(s.action?.name, c.running, c.name)
            XCTAssertEqual(s.action?.waited, c.waited, c.name)
        }
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

    /// Clamping the run surface's pager, whose domain is a failure slot at -1
    /// followed by the kept results.
    ///
    /// Kept because `record` does `recent[i]` with this as the only guard, so a
    /// wrong clamp indexes out of bounds — and CLAUDE.md names clamping as a
    /// tricky invariant worth covering. `openingResultIndex` is
    /// deliberately NOT tested: getting it wrong
    /// shows the user a result they already read, which is a visible annoyance
    /// rather than a silent bug, and cannot crash.
    func testRunSurfacePagerClamping() {
        // In range at both ends, never wrapping (wrapping would make the ends
        // indistinguishable), and -1 addressable only when a failure holds it.
        XCTAssertEqual(S.clampResultIndex(9, recentCount: 3, hasFailure: false), 2)
        XCTAssertEqual(S.clampResultIndex(-5, recentCount: 3, hasFailure: true), -1)
        XCTAssertEqual(S.clampResultIndex(-1, recentCount: 3, hasFailure: false), 0)
        XCTAssertEqual(S.clampResultIndex(0, recentCount: 0, hasFailure: true), -1)
    }

    // MARK: - Nested start returns the live run id (P1)

    /// Locks down: a chain running inside an already-running action reported
    /// its output against a freshly minted id that `reduce` never stored, so
    /// the staleness guard dropped it and the chain's result never reached the
    /// pill. Exercised on the singleton because the bug was in `start()`'s
    /// return value, which no `reduce` row can reach.
    @MainActor
    func testNestedStartReturnsTheLiveRunId() {
        let state = ExecutionState.shared
        let outer = state.start(name: "outer")
        let inner = state.start(name: "inner chain")
        state.finish()
        state.finish()

        XCTAssertEqual(inner, outer, "a nested report must carry the outer run's id")
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
