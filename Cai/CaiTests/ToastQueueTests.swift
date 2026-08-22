import XCTest
@testable import Cai

/// The single toast slot: what a message looks like, and who gets a turn.
///
/// Both halves lock down bugs that shipped. Appearance: a failure wore a
/// success checkmark, because the channel defaulted to one. Ordering: two
/// proposals arriving a third of a second apart produced one flicker and one
/// survivor, and the first toast's dismiss timer then cut the survivor short —
/// the user knows something happened and cannot read what.
final class ToastQueueTests: XCTestCase {

    // MARK: - Appearance (P0)

    /// The outcome → appearance table every posting site depends on.
    ///
    /// P0 because the glyph is what the user believes happened, so no outcome
    /// but `.success` may ever render the checkmark. Covers the glyph, the
    /// draw-vs-name split for the Cai mark, and the length-aware dwell.
    func testOutcomeDecidesTheAppearance() {
        let long = "This proposal changed since you read it. Nothing was decided; review the new version."
        let veryLong = String(repeating: "word ", count: 40)

        // (outcome, message, expected icon, expected SF Symbol, expected dwell)
        let cases: [(ToastQueue.Outcome, String, ToastQueue.Icon, String?, TimeInterval)] = [
            // A success confirms something the user just did, and a progress
            // message answers a trigger they just pulled: both always brief,
            // however long the text is.
            (.success, "Copied to Clipboard", .success, "checkmark.circle.fill", 1.5),
            (.success, long, .success, "checkmark.circle.fill", 1.5),
            // In progress is NOT a success: nothing has completed yet, so it
            // must not wear the checkmark. DESIGN.md's ◉ marks in-progress.
            (.progress, "Generating: Summarize", .progress, "smallcircle.filled.circle", 1.5),
            // Short problems get the floor, long ones get reading time.
            (.problem, "Failed: Shell command exceeded 60s", .warning, "exclamationmark.triangle.fill", 3.5),
            (.problem, "An action is already running", .warning, "exclamationmark.triangle.fill", 3.5),
            (.problem, long, .warning, "exclamationmark.triangle.fill", 5.2),
            // The Cai mark has no SF Symbol — it is drawn from CaiLogoShape, so
            // a symbol name here would silently blank the arrival glyph.
            (.arrival, "Claude Code proposed a new action", .cai, nil, 3.5),
            // Nothing may outstay the cap: the pill cannot be dismissed.
            (.problem, veryLong, .warning, "exclamationmark.triangle.fill", 6.0),
        ]

        for (outcome, message, expectedIcon, expectedSymbol, expectedDwell) in cases {
            let presentation = ToastQueue.presentation(for: outcome, message: message)
            let label = "\(outcome) / \(message.prefix(24))"

            XCTAssertEqual(presentation.icon, expectedIcon, "icon for \(label)")
            XCTAssertEqual(presentation.icon.symbolName, expectedSymbol, "symbol for \(label)")
            XCTAssertEqual(presentation.duration, expectedDwell, accuracy: 0.001, "dwell for \(label)")

            // The invariant worth failing loudly on, whatever else the table says.
            if outcome != .success {
                XCTAssertNotEqual(
                    presentation.icon, .success,
                    "\(outcome) must never render a success checkmark"
                )
            }
        }
    }

    // MARK: - Ordering (P1)

    func testMessagesAreServedInOrder() {
        var queue = ToastQueue()
        queue.enqueue(ToastQueue.Request(message: "first"), showing: nil)
        queue.enqueue(ToastQueue.Request(message: "second"), showing: "first")

        XCTAssertEqual(queue.next()?.message, "first")
        XCTAssertEqual(queue.next()?.message, "second")
        XCTAssertNil(queue.next())
    }

    /// Only *consecutive* repeats collapse. The same sentence twice in a row
    /// reads as a rendering glitch; the same event happening again later is
    /// news, and dropping it would hide a second failure.
    func testOnlyConsecutiveRepeatsCollapse() {
        var queue = ToastQueue()

        XCTAssertFalse(
            queue.enqueue(ToastQueue.Request(message: "Action added"), showing: "Action added"),
            "Identical to what is on screen."
        )
        XCTAssertTrue(queue.isEmpty)

        XCTAssertTrue(queue.enqueue(ToastQueue.Request(message: "Action added"), showing: nil))
        XCTAssertFalse(
            queue.enqueue(ToastQueue.Request(message: "Action added"), showing: nil),
            "Identical to what is already next in line."
        )

        queue.enqueue(ToastQueue.Request(message: "Chain failed"), showing: nil)
        XCTAssertTrue(queue.enqueue(ToastQueue.Request(message: "Action added"), showing: nil))
        XCTAssertEqual(queue.pending.map(\.message), ["Action added", "Chain failed", "Action added"])
    }

    func testTheQueueDropsTheOldestBeyondItsDepth() {
        var queue = ToastQueue()
        for index in 1...6 {
            queue.enqueue(ToastQueue.Request(message: "message \(index)"), showing: nil)
        }

        XCTAssertEqual(queue.pending.count, ToastQueue.maxDepth)
        XCTAssertEqual(
            queue.pending.map(\.message),
            ["message 3", "message 4", "message 5", "message 6"],
            "A queue this deep is already narrating the past; the newest events win."
        )
    }
}
