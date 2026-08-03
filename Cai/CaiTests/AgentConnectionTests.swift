import CaiActionCore
import XCTest
@testable import Cai

/// What Settings hands the user to wire their agent up.
///
/// Worth testing because the failure is invisible: a wrong path or a bad quote
/// produces a config that never loads, and the user sees a missing tool inside
/// their agent with nothing in Cai to explain it.
final class AgentConnectionTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester")

    // MARK: - The path

    func testEveryClientPointsAtTheSymlinkNotTheAppBundle() {
        for client in AgentClient.allCases {
            let snippet = AgentConnection.snippet(for: client, home: home)
            XCTAssertTrue(
                snippet.contains("Application Support/Cai/bin/cai-mcp")
                    || snippet.contains("Application\\ Support/Cai/bin/cai-mcp"),
                "\(client.label) must use the stable path, which survives Cai being moved or updated: \(snippet)"
            )
            XCTAssertFalse(
                snippet.contains(".app/Contents"),
                "\(client.label) points into the bundle, which breaks on the next update: \(snippet)"
            )
        }
    }

    func testTheShellFormAbbreviatesHomeAndEscapesTheSpace() {
        let path = AgentConnection.shellHelperPath(home: home)

        XCTAssertEqual(path, "~/Library/Application\\ Support/Cai/bin/cai-mcp")
        XCTAssertFalse(
            path.contains("Application Support"),
            "An unescaped space truncates the argument and the command silently registers the wrong binary."
        )
    }

    func testTheJSONFormUsesAnAbsoluteUnescapedPath() {
        let snippet = AgentConnection.snippet(for: .other, home: home)

        XCTAssertTrue(snippet.contains("/Users/tester/Library/Application Support/Cai/bin/cai-mcp"), snippet)
        XCTAssertFalse(snippet.contains("~"), "JSON config readers do not expand a tilde.")
        XCTAssertFalse(snippet.contains("\\ "), "A shell escape inside JSON is a broken path.")
    }

    // MARK: - Per-client shape

    func testClaudeCodeGetsACommandToRun() {
        XCTAssertEqual(
            AgentConnection.snippet(for: .claudeCode, home: home),
            "claude mcp add cai -- ~/Library/Application\\ Support/Cai/bin/cai-mcp"
        )
    }

    func testThereIsOneTabPerDistinctThingToDo() {
        // Claude Desktop used to have its own tab showing byte-identical JSON
        // to "Other". Three tabs, two payloads.
        XCTAssertEqual(AgentClient.allCases.count, 3)
        XCTAssertEqual(
            AgentConnection.snippet(for: .cursor, home: home),
            AgentConnection.snippet(for: .other, home: home),
            "If these ever diverge, Cursor needs its own snippet rather than sharing one."
        )
    }

    func testTheOthersGetValidJSONUnderMcpServers() throws {
        for client in [AgentClient.cursor, .other] {
            let snippet = AgentConnection.snippet(for: client, home: home)
            let parsed = try JSONSerialization.jsonObject(
                with: Data(snippet.utf8)
            ) as? [String: Any]

            let servers = try XCTUnwrap(parsed?["mcpServers"] as? [String: Any], "\(client.label): no mcpServers")
            let cai = try XCTUnwrap(servers["cai"] as? [String: Any], "\(client.label): no cai entry")
            XCTAssertNotNil(cai["command"], "\(client.label): no command")
        }
    }

    func testEveryClientSaysWhatToDoWithIt() {
        for client in AgentClient.allCases {
            XCTAssertFalse(client.instruction.isEmpty, client.label)
            XCTAssertFalse(client.instruction.contains("—"), client.instruction)
        }
    }

    // MARK: - Cursor deeplink

    func testCursorDeeplinkCarriesTheConfigAsBase64() throws {
        let url = try XCTUnwrap(AgentConnection.cursorInstallURL(home: home))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(url.scheme, "cursor")
        XCTAssertEqual(components.queryItems?.first { $0.name == "name" }?.value, "cai")

        let encoded = try XCTUnwrap(components.queryItems?.first { $0.name == "config" }?.value)
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        let config = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: decoded) as? [String: String]
        )

        XCTAssertEqual(config["command"], "/Users/tester/Library/Application Support/Cai/bin/cai-mcp")
    }

    // MARK: - Copy

    func testNoConnectCopyUsesAnEmDash() {
        let strings = [
            AgentConnection.sectionTitle,
            AgentConnection.killSwitchTitle,
            AgentConnection.killSwitchCaption,
            AgentConnection.copyButtonTitle,
            AgentConnection.copiedButtonTitle,
            AgentConnection.cursorButtonTitle,
            AgentConnection.cursorFallbackCaption,
            AgentConnection.disabledCaption,
        ]
        for string in strings {
            XCTAssertFalse(string.contains("—"), string)
        }
    }

    func testTheKillSwitchCaptionPromisesApprovalRatherThanSafety() {
        // The spec's wording, verbatim: it says what happens, not that it is
        // safe. A caption claiming safety would be the app vouching for
        // whatever an agent writes.
        XCTAssertEqual(
            AgentConnection.killSwitchCaption,
            "Proposed actions always wait for your approval here before they can run."
        )
    }
}
