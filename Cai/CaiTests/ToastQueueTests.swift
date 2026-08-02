import XCTest
@testable import Cai

/// Ordering rules for the single toast slot.
///
/// The bug these lock down was visible in the app: two proposals arriving a
/// third of a second apart produced one flicker and one survivor, and the
/// first toast's dismiss timer then cut the survivor short. The user knows
/// something happened and cannot read what.
final class ToastQueueTests: XCTestCase {

    func testMessagesAreServedInOrder() {
        var queue = ToastQueue()
        queue.enqueue(ToastQueue.Request(message: "first"), showing: nil)
        queue.enqueue(ToastQueue.Request(message: "second"), showing: "first")

        XCTAssertEqual(queue.next()?.message, "first")
        XCTAssertEqual(queue.next()?.message, "second")
        XCTAssertNil(queue.next())
    }

    func testDurationTravelsWithTheMessage() {
        var queue = ToastQueue()
        queue.enqueue(ToastQueue.Request(message: "slow one", duration: 4), showing: nil)

        XCTAssertEqual(queue.next()?.duration, 4)
    }

    func testDefaultDurationIsTheStandardOne() {
        XCTAssertEqual(ToastQueue.Request(message: "x").duration, 1.5)
    }

    // MARK: - Collapsing repeats

    func testAMessageIdenticalToTheOneOnScreenIsDropped() {
        var queue = ToastQueue()
        XCTAssertFalse(queue.enqueue(ToastQueue.Request(message: "Action added"), showing: "Action added"))
        XCTAssertTrue(queue.isEmpty)
    }

    func testAMessageIdenticalToTheOneAlreadyQueuedIsDropped() {
        var queue = ToastQueue()
        XCTAssertTrue(queue.enqueue(ToastQueue.Request(message: "Action added"), showing: nil))
        XCTAssertFalse(queue.enqueue(ToastQueue.Request(message: "Action added"), showing: nil))
        XCTAssertEqual(queue.pending.count, 1)
    }

    func testTheSameMessageAgainLaterIsNotDropped() {
        var queue = ToastQueue()
        queue.enqueue(ToastQueue.Request(message: "Action added"), showing: nil)
        queue.enqueue(ToastQueue.Request(message: "Chain failed"), showing: nil)
        XCTAssertTrue(
            queue.enqueue(ToastQueue.Request(message: "Action added"), showing: nil),
            "Only consecutive repeats collapse; the same event happening again is news."
        )
        XCTAssertEqual(queue.pending.map(\.message), ["Action added", "Chain failed", "Action added"])
    }

    // MARK: - Depth

    func testTheQueueDropsTheOldestBeyondItsDepth() {
        var queue = ToastQueue()
        for index in 1...6 {
            queue.enqueue(ToastQueue.Request(message: "message \(index)"), showing: nil)
        }

        XCTAssertEqual(queue.pending.count, ToastQueue.maxDepth)
        XCTAssertEqual(
            queue.pending.map(\.message),
            ["message 3", "message 4", "message 5", "message 6"],
            "Six seconds of pills is already too much; the newest events win."
        )
    }
}
