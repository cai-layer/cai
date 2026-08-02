import CaiActionCore
import XCTest
@testable import Cai

/// Regression guard for the stored-shortcut format.
///
/// `cai_shortcuts` in UserDefaults holds JSON written by every version Cai has
/// ever shipped. Adding `provenance` (and moving `ShortcutType` and `ChainStep`
/// into CaiActionCore) must not change how any of it decodes: a shortcut that
/// stops decoding is a shortcut the user silently loses.
final class CaiShortcutDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> CaiShortcut {
        try JSONDecoder().decode(CaiShortcut.self, from: Data(json.utf8))
    }

    // MARK: - Legacy payloads

    func testOldestShortcutWithOnlyTheFourOriginalFieldsStillDecodes() throws {
        let shortcut = try decode("""
        {
          "id": "9F8E7D6C-5B4A-3928-1716-051423324150",
          "name": "Reddit search",
          "type": "url",
          "value": "https://www.reddit.com/search/?q=%s"
        }
        """)

        XCTAssertEqual(shortcut.name, "Reddit search")
        XCTAssertEqual(shortcut.type, .url)
        XCTAssertFalse(shortcut.autoReplaceSelection)
        XCTAssertFalse(shortcut.pinned)
        XCTAssertFalse(shortcut.runInBackground)
        XCTAssertEqual(shortcut.next, [])
        XCTAssertNil(shortcut.provenance, "A shortcut the user wrote has no provenance.")
    }

    func testShortcutWithFlagsButNoChainDecodes() throws {
        let shortcut = try decode("""
        {
          "id": "9F8E7D6C-5B4A-3928-1716-051423324151",
          "name": "Fix grammar",
          "type": "prompt",
          "value": "Fix the grammar",
          "autoReplaceSelection": true,
          "pinned": true,
          "runInBackground": false
        }
        """)

        XCTAssertTrue(shortcut.autoReplaceSelection)
        XCTAssertTrue(shortcut.pinned)
        XCTAssertEqual(shortcut.next, [])
    }

    func testShortcutWithAChainDecodesEveryStepKind() throws {
        let shortcut = try decode("""
        {
          "id": "9F8E7D6C-5B4A-3928-1716-051423324152",
          "name": "Ship it",
          "type": "shell",
          "value": "./deploy.sh",
          "runInBackground": true,
          "next": [
            {"action": {"name": "Slack"}},
            {"inlineLLM": {"directive": "shorten"}},
            {"appleShortcut": {"name": "Log build"}}
          ]
        }
        """)

        XCTAssertEqual(shortcut.type, .shell)
        XCTAssertTrue(shortcut.runInBackground)
        XCTAssertEqual(shortcut.next, [
            .action(name: "Slack"),
            .inlineLLM(directive: "shorten"),
            .appleShortcut(name: "Log build"),
        ])
    }

    func testUnknownTypeStillFailsRatherThanDefaulting() {
        XCTAssertThrowsError(try decode("""
        {"id": "9F8E7D6C-5B4A-3928-1716-051423324153", "name": "X", "type": "applescript", "value": "beep"}
        """))
    }

    // MARK: - Round trip with provenance

    func testProvenanceSurvivesAStorageRoundTrip() throws {
        let authored = CaiShortcut(
            name: "File issue",
            type: .shell,
            value: "gh issue create",
            provenance: ActionProvenance(
                source: .mcp,
                client: "Claude Code",
                authoredAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        let data = try JSONEncoder().encode([authored])
        let restored = try JSONDecoder().decode([CaiShortcut].self, from: data)

        XCTAssertEqual(restored, [authored])
        XCTAssertEqual(restored.first?.provenance?.client, "Claude Code")
    }

    func testChainEncodingShapeIsUnchanged() throws {
        let shortcut = CaiShortcut(name: "X", type: .prompt, value: "y", next: [.action(name: "Slack")])
        let json = String(decoding: try JSONEncoder().encode(shortcut), as: UTF8.self)

        XCTAssertTrue(
            json.contains("{\"action\":{\"name\":\"Slack\"}}"),
            "Moving ChainStep into CaiActionCore must not change its Codable shape: \(json)"
        )
    }

    // MARK: - Snapshot bridging

    func testSnapshotRoundTripPreservesEveryField() {
        let shortcut = CaiShortcut(
            name: "Ship it",
            type: .shell,
            value: "./deploy.sh",
            autoReplaceSelection: true,
            pinned: true,
            runInBackground: true,
            next: [.action(name: "Slack")]
        )
        let rebuilt = CaiShortcut(snapshot: shortcut.actionSnapshot, provenance: nil)

        XCTAssertEqual(rebuilt, shortcut)
    }
}
