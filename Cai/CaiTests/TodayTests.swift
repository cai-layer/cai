import AppKit
import XCTest
@testable import Cai

final class TodayTests: XCTestCase {
    private let header = #"{"v":1,"type":"header","generated":"2026-11-02T08:00:00Z","sources":[{"name":"slack","status":"read"},{"name":"linear","status":"skipped","reason":"needs sign-in"}]}"#

    private func line(
        url: String = "https://example.slack.com/a/1",
        title: String = "Send the numbers",
        priority: String = "P1",
        created: String = "2026-11-01T08:00:00Z",
        activity: String = "2026-11-02T07:00:00Z",
        prompt: String = "Draft a reply.",
        links: String? = nil,
        extra: String = ""
    ) -> String {
        let links = links ?? "[\"\(url)\"]"
        return #"{"id":"\#(url)","url":"\#(url)","source":"slack","title":"\#(title)","why":"Blocked.","who":"Alex","priority":"\#(priority)","created":"\#(created)","activity":"\#(activity)","prompt":"\#(prompt)","links":\#(links)\#(extra)}"#
    }

    private func item(_ text: String) -> TodayItem { TodayFile.item(fromLine: text)! }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: - (P0) Untrusted lines never render as a row

    /// Locks down: the file is written by an agent reading email and chat, so a
    /// line that could send the user somewhere unexpected, or show a prompt
    /// other than the one copied, is refused whole rather than repaired.
    func testRefusedLines() {
        let longPrompt = String(repeating: "a", count: TodayFile.maxPrompt + 1)
        let elevenLinks = "[" + (0...10).map { "\"https://example.com/\($0)\"" }.joined(separator: ",") + "]"
        let cases: [(name: String, line: String, accepted: Bool)] = [
            ("a well-formed item", line(), true),
            ("http main link", line(url: "http://example.com/a"), false),
            ("javascript main link", line(url: "javascript:alert(1)"), false),
            ("file main link", line(url: "file:///etc/passwd"), false),
            ("https without a host", line(url: "https:///path"), false),
            ("unknown priority", line(priority: "P9"), false),
            ("unparseable date", line(activity: "yesterday"), false),
            ("prompt over the cap", line(prompt: longPrompt), false),
            ("more than 10 links", line(links: elevenLinks), false),
            ("a link that isn't a string", line(links: "[42]"), false),
            ("title made only of control characters", line(title: "\\u202E\\u200B"), false),
            ("not JSON", "{ nope", false),
        ]
        for c in cases {
            XCTAssertEqual(TodayFile.item(fromLine: c.line) != nil, c.accepted, c.name)
        }
    }

    /// Locks down: what details shows is what ⌘C copies, and only https links
    /// can be opened; a display field can't reorder text with bidi controls.
    func testWhatTheUserSeesIsWhatTheyGet() {
        let parsed = item(line(
            title: "Approve \\u202Eexe.txt",
            prompt: "Line one\\nLine two",
            links: #"["https://example.slack.com/a/1","http://example.com/x","mailto:a@example.com"]"#
        ))
        XCTAssertEqual(parsed.title, "Approve exe.txt")
        XCTAssertEqual(parsed.prompt, "Line one\nLine two")
        XCTAssertEqual(parsed.links.map(TodayItem.isOpenable), [true, false, false])
    }

    /// Locks down: a header with another version shows nothing (its items may
    /// mean something else), refused lines are counted for "items not shown",
    /// and a duplicate subject keeps its first line.
    func testWholeFile() {
        let cases: [(name: String, text: String, items: Int, notShown: Int, hasHeader: Bool)] = [
            ("header and two items", [header, line(), line(url: "https://example.com/b")].joined(separator: "\n"), 2, 0, true),
            ("one bad line is counted, the rest show", [header, line(), line(url: "http://x")].joined(separator: "\n"), 1, 1, true),
            ("a duplicate url is one subject, and not counted as refused", [header, line(), line(title: "Again")].joined(separator: "\n"), 1, 0, true),
            ("unknown version shows nothing", [header.replacingOccurrences(of: #""v":1"#, with: #""v":2"#), line()].joined(separator: "\n"), 0, 1, false),
            ("no header shows nothing", line(), 0, 0, false),
            ("blank lines are ignored", [header, "", line(), "  "].joined(separator: "\n"), 1, 0, true),
        ]
        for c in cases {
            let parsed = TodayFile.parse(c.text)
            XCTAssertEqual(parsed.items.count, c.items, c.name)
            XCTAssertEqual(parsed.notShown, c.notShown, c.name)
            XCTAssertEqual(parsed.header != nil, c.hasHeader, c.name)
        }
        XCTAssertEqual(TodayFile.parse(header).header?.sources.map(\.read), [true, false])
    }

    // MARK: - (P1) Done, dismissed and snoozed items stay hidden until the source moves

    /// Locks down: an item the user handled stays hidden across a rebuild, comes
    /// back when its source shows newer activity, and a snooze ends at its time.
    func testVisibility() {
        let now = date("2026-11-02T10:00:00Z")
        let base = item(line(activity: "2026-11-02T07:00:00Z"))
        let newer = item(line(activity: "2026-11-02T09:30:00Z"))
        let calendar = Calendar(identifier: .gregorian)
        let cases: [(name: String, state: TodayState, item: TodayItem, at: Date, expected: TodayState.Visibility)] = [
            ("untouched", TodayState(), base, now, .shown),
            ("done", TodayState().marking(base, .done, now: now), base, now, .hidden),
            ("dismissed", TodayState().marking(base, .dismissed, now: now), base, now, .hidden),
            ("done, then new activity", TodayState().marking(base, .done, now: now), newer, now, .shown),
            ("snoozed", TodayState().marking(base, .snoozed, now: now, calendar: calendar), base, now, .snoozed),
            ("snoozed, after the snooze ends", TodayState().marking(base, .snoozed, now: now, calendar: calendar), base, now.addingTimeInterval(2 * 86_400), .shown),
            ("snoozed, then new activity", TodayState().marking(base, .snoozed, now: now, calendar: calendar), newer, now, .shown),
            ("done, then cleared (unsnooze or undo)", TodayState().marking(base, .done, now: now).clearing(base), base, now, .shown),
        ]
        for c in cases {
            XCTAssertEqual(c.state.visibility(of: c.item, now: c.at), c.expected, c.name)
        }
    }

    /// Locks down: snooze has one setting, tomorrow at 09:00 local time, from
    /// any time of day including just before midnight.
    func testSnoozeEnd() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let cases: [(from: String, until: String)] = [
            ("2026-11-02T08:00:00+01:00", "2026-11-03T09:00:00+01:00"),
            ("2026-11-02T23:59:00+01:00", "2026-11-03T09:00:00+01:00"),
            ("2026-11-02T00:01:00+01:00", "2026-11-03T09:00:00+01:00"),
        ]
        for c in cases {
            XCTAssertEqual(TodayState.snoozeEnd(after: date(c.from), calendar: calendar), date(c.until), c.from)
        }
    }

    // MARK: - (P1) Order, groups and filtering

    /// Locks down: P0 and P1 on top, oldest first within a priority, P2 and P3
    /// under Later, snoozed apart; typing searches every group as one list.
    func testSectionsAndFilter() {
        let now = date("2026-11-02T10:00:00Z")
        let p1New = item(line(url: "https://example.com/1", title: "Review sync race", priority: "P1", created: "2026-11-02T08:00:00Z"))
        let p1Old = item(line(url: "https://example.com/2", title: "Answer pricing question", priority: "P1", created: "2026-10-30T08:00:00Z"))
        let p0 = item(line(url: "https://example.com/3", title: "Board pack numbers", priority: "P0"))
        let p3 = item(line(url: "https://example.com/4", title: "Review helm chart", priority: "P3"))
        let p2 = item(line(url: "https://example.com/5", title: "Spec review", priority: "P2"))
        let state = TodayState().marking(p2, .snoozed, now: now)
        let all = [p1New, p3, p1Old, p0, p2]

        let sections = TodayList.sections(all, state: state, now: now)
        XCTAssertEqual(sections.now.map(\.title), ["Board pack numbers", "Answer pricing question", "Review sync race"])
        XCTAssertEqual(sections.later.map(\.title), ["Review helm chart"])
        XCTAssertEqual(sections.snoozed.map(\.title), ["Spec review"])

        let cases: [(query: String, titles: [String])] = [
            ("rev", ["Review sync race", "Review helm chart", "Spec review"]),
            ("helm", ["Review helm chart"]),
            ("alex", ["Board pack numbers", "Answer pricing question", "Review sync race", "Review helm chart", "Spec review"]),
            ("elm", []),
            ("", []),
        ]
        for c in cases {
            XCTAssertEqual(TodayList.filtered(all, state: state, query: c.query, now: now).map(\.title), c.titles, c.query)
        }
    }

    // MARK: - (P1) The Today screen's keys and next item

    /// Locks down: ⌘⌫ dismisses while a plain ⌫ stays with the filter, ⌘C is
    /// claimed only on Today (elsewhere it copies selected text), and a chord
    /// with an extra modifier (⌘⇧Z is redo) is never mistaken for a command.
    func testCommandKeys() {
        let cases: [(name: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, active: Bool, expected: TodayCommand?)] = [
            ("⌘⌫ dismisses", 51, .command, true, .dismiss),
            ("plain ⌫ edits the filter", 51, [], true, nil),
            ("⌘↵ copies and closes", 36, .command, true, .copyAndClose),
            ("plain ↵ keeps its own path", 36, [], true, nil),
            ("⌘C copies", 8, .command, true, .copy),
            ("⌘C off Today copies text", 8, .command, false, nil),
            ("⌘O opens", 31, .command, true, .open),
            ("⌘D done, caps lock ignored", 2, [.command, .capsLock], true, .done),
            ("⌘S snoozes", 1, .command, true, .snooze),
            ("⌘Z undoes", 6, .command, true, .undo),
            ("⌘⇧Z is redo, not undo", 6, [.command, .shift], true, nil),
            ("⌘⌥D is not done", 2, [.command, .option], true, nil),
            ("⌘T is not a Today command", 17, .command, true, nil),
            ("⌘R refreshes", 15, .command, true, .refresh),
            ("⌘⇧R is not refresh", 15, [.command, .shift], true, nil),
            ("⌘R off Today falls through", 15, .command, false, nil),
        ]
        for c in cases {
            XCTAssertEqual(TodayNavigation.command(keyCode: c.keyCode, modifiers: c.modifiers, todayActive: c.active), c.expected, c.name)
        }
    }

    /// Locks down: done, dismiss or snooze from details lands on the next item,
    /// the previous one at the end, and back on the list when none is left.
    func testNeighbourAfterRemoval() {
        let a = item(line(url: "https://example.com/a"))
        let b = item(line(url: "https://example.com/b"))
        let c = item(line(url: "https://example.com/c"))
        let cases: [(name: String, removed: TodayItem, list: [TodayItem], expected: TodayItem?)] = [
            ("first goes to second", a, [a, b, c], b),
            ("middle goes to next", b, [a, b, c], c),
            ("last goes to previous", c, [a, b, c], b),
            ("only item goes back to the list", a, [a], nil),
            ("item not in the list", c, [a, b], nil),
        ]
        for t in cases {
            XCTAssertEqual(TodayNavigation.neighbour(of: t.removed.url, in: t.list), t.expected, t.name)
        }
    }

    // MARK: - (P1) state.json round trip

    /// Locks down: an item handled before a relaunch is still handled after it,
    /// including when its activity carries a fraction of a second (an ISO
    /// string would drop it and the item would come back every launch), and a
    /// state file of an unknown version is not read.
    func testStateSurvivesSaveAndLoad() throws {
        let now = date("2026-11-02T10:00:00Z")
        let fractional = item(line(activity: "2026-11-02T07:00:00.893579Z"))
        let cases: [(kind: TodayState.Entry.Kind, expected: TodayState.Visibility)] = [
            (.done, .hidden), (.dismissed, .hidden), (.snoozed, .snoozed),
        ]
        for c in cases {
            let saved = TodayState().marking(fractional, c.kind, now: now)
            let loaded = try XCTUnwrap(TodayStore.decodeState(TodayStore.encodeState(saved)))
            XCTAssertEqual(loaded, saved, "\(c.kind)")
            XCTAssertEqual(loaded.visibility(of: fractional, now: now), c.expected, "\(c.kind)")
        }
        var future = TodayState()
        future.v = 2
        XCTAssertNil(TodayStore.decodeState(try TodayStore.encodeState(future)))
    }
}
