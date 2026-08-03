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

    func testClaudeCodeGetsAUserScopedCommandToRun() {
        // --scope user, because the default is local: Cai is system-wide, and
        // a local-scoped connection silently vanishes outside the directory
        // the command happened to be run from.
        XCTAssertEqual(
            AgentConnection.snippet(for: .claudeCode, home: home),
            "claude mcp add --scope user cai -- ~/Library/Application\\ Support/Cai/bin/cai-mcp"
        )
    }

    func testCodexGetsItsOwnCLICommandBecauseItDoesNotReadJSON() {
        // Codex reads TOML from ~/.codex/config.toml; the JSON payload would
        // never load there. Its CLI writes the right format itself.
        XCTAssertEqual(
            AgentConnection.snippet(for: .codex, home: home),
            "codex mcp add cai -- ~/Library/Application\\ Support/Cai/bin/cai-mcp"
        )
    }

    func testThereIsOneTabPerDistinctThingToDo() {
        // Claude Desktop used to have its own tab showing byte-identical JSON
        // to "Other". Four tabs, four distinct payloads or delivery methods.
        XCTAssertEqual(AgentClient.allCases.count, 4)
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

    func testTheJSONFormSurvivesAHomePathWithAQuoteOrBackslash() throws {
        // A quote or backslash interpolated raw into the snippet is invalid
        // JSON, and the config silently never loads in the user's client.
        let home = URL(fileURLWithPath: "/Users/A\"User\\Odd")
        let snippet = AgentConnection.snippet(for: .other, home: home)

        let parsed = try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any]
        let servers = try XCTUnwrap(parsed?["mcpServers"] as? [String: Any])
        let cai = try XCTUnwrap(servers["cai"] as? [String: Any])
        XCTAssertEqual(
            cai["command"] as? String,
            "/Users/A\"User\\Odd/Library/Application Support/Cai/bin/cai-mcp"
        )
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

    func testTheDeeplinkSurvivesAFormStyleDecoder() throws {
        // A non-ASCII home path is the only way this payload's base64 grows a
        // "+", and a form-style decoder reads a bare "+" as a space, so the
        // config silently stops decoding for exactly those users. Cursor's own
        // generators percent-encode it; so must we.
        let home = URL(fileURLWithPath: "/Users/田中")
        let url = try XCTUnwrap(AgentConnection.cursorInstallURL(home: home))
        let query = try XCTUnwrap(url.query)

        XCTAssertFalse(
            query.contains("+"),
            "A bare + in the query is a space to a form-style decoder: \(url.absoluteString)"
        )

        // Decode the way a form decoder would: percent-decode, then base64.
        let encoded = try XCTUnwrap(
            query.split(separator: "&")
                .first { $0.hasPrefix("config=") }?
                .dropFirst("config=".count)
        )
        let decoded = try XCTUnwrap(String(encoded).removingPercentEncoding)
        let data = try XCTUnwrap(Data(base64Encoded: decoded))
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(config["command"], "/Users/田中/Library/Application Support/Cai/bin/cai-mcp")
    }

    // MARK: - The instructions and the installer agree

    func testTheDisplayedPathIsWhereTheInstallerActuallyWrites() {
        // AgentConnection derives the path from $HOME; HelperInstaller creates
        // the symlink under CaiSupportPaths.root. They resolve identically only
        // while the app is unsandboxed — this pins the two together so a future
        // support-root change cannot ship instructions pointing at nothing.
        XCTAssertEqual(AgentConnection.helperPath(), CaiSupportPaths.helperSymlink().path)
    }

    // MARK: - Copy

    func testNoConnectCopyUsesAnEmDash() {
        let strings = [
            AgentConnection.killSwitchTitle,
            AgentConnection.killSwitchCaption,
            AgentConnection.copyButtonTitle,
            AgentConnection.copiedButtonTitle,
            AgentConnection.cursorButtonTitle,
            AgentConnection.cursorFallbackCaption,
            AgentConnection.disabledCaption,
            AgentConnection.helperMissingCaption,
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
