import CaiActionCore
import Foundation

/// What to hand a user so their agent can reach Cai.
///
/// One entry per distinct payload, not one per client. Claude Code and Codex
/// take CLI commands, Cursor has a one-click install deeplink, and everything
/// else takes the same JSON object, so listing Claude Desktop separately was
/// a tab showing byte-identical JSON to "Other".
///
/// Getting any of it wrong is invisible: a config that never loads produces no
/// error anywhere the user will look. Pure and table-tested for the same reason
/// the approval copy is, a wrong path here is a feature that silently does not
/// exist.
///
/// Every instruction names the **symlink**, never the app bundle. The bundle
/// path breaks when Cai is moved, renamed, or replaced by an update, and the
/// failure surfaces inside the user's agent as a missing tool rather than as
/// anything Cai can explain.
enum AgentClient: String, CaseIterable, Identifiable {
    case claudeCode
    case cursor
    case codex
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .other: return "Other"
        }
    }

    /// How the user applies it, in the fewest words that are still true.
    var instruction: String {
        switch self {
        case .claudeCode, .codex:
            return "Run this in your terminal."
        case .cursor:
            return "One click. Cursor opens and adds Cai for you."
        case .other:
            return "Merge into your MCP client's JSON config, such as Claude Desktop's claude_desktop_config.json."
        }
    }
}

enum AgentConnection {

    // MARK: - Copy

    static let killSwitchTitle = "Allow agents to propose actions"
    static let killSwitchCaption = "Proposed actions always wait for your approval here before they can run."
    static let copyButtonTitle = "Copy"
    static let copiedButtonTitle = "Copied"
    static let cursorButtonTitle = "Add to Cursor"
    /// Shown under the deeplink button. Cursor takes the one-click install, but
    /// an older build or a locked-down setup may not, and a dead button with no
    /// alternative is a dead end.
    static let cursorFallbackCaption = "Or paste this into Cursor Settings, MCP:"
    /// Shown in place of the command when the switch is off, so the section
    /// explains itself rather than just dimming.
    static let disabledCaption = "Turn this on to let an agent propose actions. Nothing it proposes can run until you approve it."
    /// Shown in place of the snippet when the helper symlink is missing even
    /// after a repair attempt: handing out a path that points at nothing would
    /// fail invisibly inside the user's agent.
    static let helperMissingCaption = "Cai could not install its connection helper. Relaunch Cai to try again, or reinstall it if this keeps happening."

    // MARK: - The path everything points at

    /// The stable path, with `$HOME` written as `~` for a command line and in
    /// full for a JSON file, since JSON config readers do not expand `~`.
    static func helperPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        CaiSupportPaths.helperSymlink(in: home.appendingPathComponent("Library/Application Support/Cai")).path
    }

    /// Shell form: `~` and an escaped space, because the path contains one and
    /// an unescaped "Application Support" silently truncates the argument.
    static func shellHelperPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let full = helperPath(home: home)
        let abbreviated = full.replacingOccurrences(of: home.path, with: "~")
        return abbreviated.replacingOccurrences(of: " ", with: "\\ ")
    }

    // MARK: - Per-client payload

    /// The text the copy button puts on the clipboard.
    static func snippet(
        for client: AgentClient,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        switch client {
        case .claudeCode:
            // --scope user, because the default is local: without it the
            // connection exists only in the directory the command was run
            // from, and Cai is a system-wide app.
            return "claude mcp add --scope user cai -- \(shellHelperPath(home: home))"
        case .codex:
            // Codex reads TOML from ~/.codex/config.toml, so the JSON payload
            // would never load there; its own CLI writes the right format.
            return "codex mcp add cai -- \(shellHelperPath(home: home))"
        case .cursor, .other:
            // Absolute path, unescaped: this is JSON, not a shell.
            return """
                {
                  "mcpServers": {
                    "cai": {
                      "command": "\(helperPath(home: home))"
                    }
                  }
                }
                """
        }
    }

    /// Cursor publishes an install deeplink, so for that one client the whole
    /// thing really is one click. Base64 of the server's config object, per
    /// their documented format.
    ///
    /// Deliberately NOT us writing their config file: a scheme they publish and
    /// own cannot corrupt a file that also holds the user's other servers.
    static func cursorInstallURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let config = ["command": helperPath(home: home)]
        guard
            let json = try? JSONSerialization.data(withJSONObject: config),
            var components = URLComponents(string: "cursor://anysphere.cursor-deeplink/mcp/install")
        else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "name", value: "cai"),
            URLQueryItem(name: "config", value: json.base64EncodedString()),
        ]
        // URLComponents leaves "+" bare in queries, but a form-style decoder
        // reads a bare "+" as a space and the base64 stops decoding. Only
        // non-ASCII home paths can put one in this payload, and for them the
        // button would fail with nothing to see. Cursor's own generators run
        // the config through encodeURIComponent, which escapes it too.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
