import XCTest
@testable import Cai

/// (P1) The line actually drains. `RunQueue.isBusy` decides whether a new
/// action is queued and so whether it starts as `waited`, which turns every
/// paste-back into a copy. A count that never returns to zero would queue
/// every later action and stop auto-replace from pasting until relaunch, and
/// nothing in the app would say why.
@MainActor
final class RunQueueTests: XCTestCase {

    /// Locks down: items run in the order they were admitted, a foreground
    /// turn waits for everything ahead of it, and once all of it has finished
    /// (including a turn cancelled while it waited) the queue is idle again.
    func testLineRunsInOrderAndDrainsToIdle() async throws {
        XCTAssertFalse(RunQueue.isBusy, "a previous test left the queue busy")
        var order: [String] = []
        let (gate, open) = AsyncStream<Void>.makeStream()

        RunQueue.run(name: "A", input: "", icon: "") { _ in
            for await _ in gate {}
            order.append("A")
        }
        RunQueue.run(name: "B", input: "", icon: "") { _ in order.append("B") }
        XCTAssertTrue(RunQueue.isBusy)
        XCTAssertEqual(ExecutionState.shared.queuedCount, 1, "B waits behind A")

        // A foreground answer cancelled while it waits must still give its
        // place back.
        let abandoned = Task { try await RunQueue.acquireTurn() }
        abandoned.cancel()

        open.finish()
        let turn = try await RunQueue.acquireTurn()
        XCTAssertEqual(order, ["A", "B"])
        turn.release()

        _ = await abandoned.result
        XCTAssertFalse(RunQueue.isBusy)
        XCTAssertFalse(ExecutionState.shared.isRunning)
        XCTAssertEqual(ExecutionState.shared.queuedCount, 0)
    }

    /// Locks down: a streamed answer holds the line only while its stream is
    /// consumed. Esc cancels the view's task, which must hand the line back;
    /// otherwise the queue stays busy for the rest of the session.
    func testStreamedAnswerReleasesTheLineWhenItsConsumerStops() async throws {
        XCTAssertFalse(RunQueue.isBusy, "a previous test left the queue busy")
        // An upstream that never finishes on its own, like a long generation.
        let (upstream, keepOpen) = AsyncThrowingStream<String, Error>.makeStream()
        let generator = RunQueue.inTurn { upstream }

        let consumer = Task {
            let stream = try await generator()
            for try await _ in stream {}
        }
        await waitUntil { RunQueue.isBusy }
        XCTAssertTrue(RunQueue.isBusy, "the answer holds the line while it streams")

        consumer.cancel()
        _ = await consumer.result
        await waitUntil { !RunQueue.isBusy }
        XCTAssertFalse(RunQueue.isBusy, "Esc must give the line back")
        keepOpen.finish()
    }

    /// Yields to the main actor until `condition` holds, up to a bound.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }
}
