import XCTest
@testable import Cai

/// Where a finished run's output goes. One table over the whole input space
/// (see "Test economy" in CLAUDE.md): the rules interact — background outranks
/// an explicit "Show in Cai", a consuming destination outranks both — and
/// getting the precedence wrong either loses output (the bug this fixes) or
/// pops a window at someone mid-typing.
final class ResultRoutingTests: XCTestCase {

    func testRoutingTable() {
        typealias Terminal = ResultRouting.TerminalStep

        let cases: [(text: String, terminal: Terminal, background: Bool,
                     expected: ResultRouting, why: String)] = [
            // A destination took it — unchanged behaviour, toast confirms.
            ("done", .consumingDestination, false, .consumed,
             "destination consumed the output"),
            ("done", .consumingDestination, true, .consumed,
             "consumed wins over the background flag too"),

            // Blank output is not a result, whatever produced it.
            ("", .producesText, false, .nothing, "empty output"),
            ("   \n\t ", .producesText, false, .nothing, "whitespace-only output"),
            ("", .showInCai, false, .nothing,
             "Show in Cai with nothing to show opens nothing"),

            // The background flag always wins over showing a window.
            ("answer", .producesText, true, .record, "background records quietly"),
            ("answer", .showInCai, true, .record,
             "background outranks an explicit Show in Cai — the whole point of the flag"),

            // Foreground: explicit terminator pops, implicit one records.
            ("answer", .showInCai, false, .showInPanel,
             "foreground Show in Cai asked for the panel"),
            ("answer", .producesText, false, .record,
             "implicit fallback — kept, never lost, never interrupts"),
        ]

        for c in cases {
            XCTAssertEqual(
                ResultRouting.route(
                    text: c.text, terminal: c.terminal, runInBackground: c.background
                ),
                c.expected,
                c.why
            )
        }
    }
}
