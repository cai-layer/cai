import XCTest
@testable import Cai

final class ClipboardHistoryOrderingTests: XCTestCase {
    typealias Entry = ClipboardHistory.Entry

    // MARK: - (P1) Re-copy from history moves the entry to the top

    /// Locks down: picking a clip from history moves it to the front with a
    /// fresh timestamp and the SAME id (the ⌘0 list selects by id), leaves the
    /// rest in order, and is a no-op for an id not in the list (pinned entries
    /// live in their own list and keep the user's order).
    func testPromoting() {
        let old = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 100)
        let entries = ["a", "b", "c"].map { Entry(text: $0, timestamp: old, sourceBundleId: "com.example.\($0)") }
        let cases: [(name: String, id: UUID, order: [String])] = [
            ("middle entry moves to the top", entries[1].id, ["b", "a", "c"]),
            ("last entry moves to the top", entries[2].id, ["c", "a", "b"]),
            ("top entry stays on top", entries[0].id, ["a", "b", "c"]),
            ("unknown id (a pinned entry) changes nothing", UUID(), ["a", "b", "c"]),
        ]
        for c in cases {
            let result = ClipboardHistory.promoting(c.id, in: entries, at: now)
            XCTAssertEqual(result.map(\.text), c.order, c.name)
            if let moved = result.first, moved.id == c.id {
                XCTAssertEqual(moved.timestamp, now, c.name)
                XCTAssertEqual(moved.sourceBundleId, "com.example.\(moved.text)", c.name)
            }
        }
    }

    // MARK: - (P1) Source app attribution

    /// Locks down: a copy made before an app switch goes to the app the user
    /// left (⌘C then ⌘Tab), a copy made after it to the frontmost app (⌘Tab
    /// then ⌘C), and Cai never labels a clip as its own. A wrong rule puts the
    /// wrong app's icon on every clip.
    func testSourceBundleId() {
        let cai = "com.soyasis.cai"
        let cases: [(name: String, frontmost: String?, previous: String?, copiedBeforeSwitch: Bool, expected: String?)] = [
            ("copy after the switch (or no switch): frontmost app", "com.apple.Safari", "com.apple.mail", false, "com.apple.Safari"),
            ("copy before the switch: the app the user left", "com.apple.Safari", "com.apple.mail", true, "com.apple.mail"),
            ("Cai frontmost: nil", cai, "com.apple.mail", false, nil),
            ("copied in Cai, then switched away: nil", "com.apple.Safari", cai, true, nil),
            ("unknown frontmost: nil", nil, nil, false, nil),
        ]
        for c in cases {
            XCTAssertEqual(
                ClipboardHistory.sourceBundleId(frontmost: c.frontmost, previous: c.previous, copiedBeforeSwitch: c.copiedBeforeSwitch, ownBundleId: cai),
                c.expected,
                c.name
            )
        }
    }
}
