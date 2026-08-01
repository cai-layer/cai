import XCTest
import CaiActionCore

/// Chain name resolution has to match `ChainExecutor.resolve(_:)` exactly: if
/// the approval sheet resolves "Notes" to a different thing than the runtime
/// does, the user approves one action and gets another.
final class ChainResolutionTests: XCTestCase {

    private let collision = KnownActions(
        shortcuts: [CoreFixture.snapshot(name: "Notes", type: .shell, value: "echo shortcut")],
        destinations: [DestinationSummary(name: "Notes", kind: .applescript)],
        builtInActionNames: ["Notes", "Summarize"]
    )

    func testShortcutsWinOverDestinationsAndBuiltIns() {
        guard case .shortcut(let resolved) = collision.resolveChainName("Notes") else {
            return XCTFail("A user shortcut must beat a same-named destination.")
        }
        XCTAssertEqual(resolved.type, .shell)
    }

    func testDestinationsWinOverBuiltIns() {
        let known = KnownActions(
            shortcuts: [],
            destinations: [DestinationSummary(name: "Summarize", kind: .webhook)],
            builtInActionNames: ["Summarize"]
        )
        guard case .destination(let resolved) = known.resolveChainName("Summarize") else {
            return XCTFail("A destination must beat a built-in of the same name.")
        }
        XCTAssertEqual(resolved.kind, .webhook)
    }

    func testBuiltInsResolveLast() {
        XCTAssertEqual(CoreFixture.known.resolveChainName("Summarize"), .builtIn("Summarize"))
    }

    func testUnknownNameIsUnresolved() {
        XCTAssertEqual(CoreFixture.known.resolveChainName("Nope"), .unresolved)
    }

    func testResolutionIsCaseSensitiveLikeTheExecutor() {
        XCTAssertEqual(CoreFixture.known.resolveChainName("summarize"), .unresolved)
    }

    func testUnresolvedNamesListOnlyCoversActionSteps() {
        let steps: [ChainStep] = [
            .action(name: "Summarize"),
            .action(name: "Missing one"),
            .action(name: "Missing two"),
            .inlineLLM(directive: "not checked"),
            .appleShortcut(name: "also not checked"),
        ]
        XCTAssertEqual(
            CoreFixture.known.unresolvedChainStepNames(in: steps),
            ["Missing one", "Missing two"]
        )
    }

    func testEmptyChainResolvesToNothingMissing() {
        XCTAssertEqual(CoreFixture.known.unresolvedChainStepNames(in: []), [])
    }
}
