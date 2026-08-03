import CaiActionCore
import Foundation

/// What to hand a user so their agent can reach Cai.
///
/// Three entries, not one per client. Claude Code takes a CLI command, Cursor
/// has a one-click install deeplink, and everything else takes the same JSON
/// object, so listing Claude Desktop separately was three tabs showing two
/// things.
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
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .other: return "Other"
        }
    }

    /// How the user applies it, in the fewest words that are still true.
    var instruction: String {
        switch self {
        case .claudeCode:
            return "Run this in your terminal."
        case .cursor:
            return "One click. Cursor opens and adds Cai for you."
        case .other:
            return "Paste into Claude Desktop, Codex, or any other MCP client, under mcpServers."
        }
    }
}

enum AgentConnection {

    // MARK: - Copy

    static let sectionTitle = "Connect your agent"
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
            return "claude mcp add cai -- \(shellHelperPath(home: home))"
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
        return components.url
    }
}
