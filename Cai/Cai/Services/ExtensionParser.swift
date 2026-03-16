import Foundation
import Yams

// MARK: - Extension Parser

/// Parses community extension YAML (with `# cai` header) into CaiShortcut or OutputDestination.
/// Rejects applescript/shell types for security — those must be created locally.
struct ExtensionParser {

    // MARK: - Result

    enum ParsedExtension {
        case shortcut(CaiShortcut, author: String?, description: String?)
        case destination(OutputDestination, author: String?, description: String?)

        var name: String {
            switch self {
            case .shortcut(let s, _, _): return s.name
            case .destination(let d, _, _): return d.name
            }
        }

        var author: String? {
            switch self {
            case .shortcut(_, let a, _): return a
            case .destination(_, let a, _): return a
            }
        }

        var extensionDescription: String? {
            switch self {
            case .shortcut(_, _, let d): return d
            case .destination(_, _, let d): return d
            }
        }

        var typeLabel: String {
            switch self {
            case .shortcut(let s, _, _):
                switch s.type {
                case .prompt: return "Prompt Shortcut"
                case .url: return "URL Shortcut"
                case .shell: return "Shell Command"
                }
            case .destination(let d, _, _):
                switch d.type {
                case .webhook: return "Webhook Destination"
                case .deeplink: return "Deeplink Destination"
                default: return "Destination"
                }
            }
        }

        var icon: String {
            switch self {
            case .shortcut: return "bolt.fill"
            case .destination(let d, _, _): return d.icon
            }
        }

        /// Returns a detail string for security-sensitive types (e.g. webhook URL).
        var securityDetail: String? {
            switch self {
            case .shortcut(let s, _, _):
                if s.type == .shell { return s.value }
                return nil
            case .destination(let d, _, _):
                if case .webhook(let config) = d.type {
                    return config.url
                }
                if case .deeplink(let template) = d.type {
                    return template
                }
                return nil
            }
        }
    }

    enum ParseError: LocalizedError {
        case invalidYAML
        case missingField(String)
        case unsupportedType(String)
        case blockedType(String)
        case insecureURL

        var errorDescription: String? {
            switch self {
            case .invalidYAML:
                return "Invalid extension format"
            case .missingField(let field):
                return "Missing required field: \(field)"
            case .unsupportedType(let type):
                return "Unknown extension type: \(type)"
            case .blockedType(let type):
                return "\(type) extensions must be created locally for security"
            case .insecureURL:
                return "Webhook URL must use HTTPS"
            }
        }
    }

    // MARK: - Parse

    /// Parses a YAML string (with `# cai` header already detected) into a ParsedExtension.
    /// Set `allowShell` to true when installing from the curated repo (reviewed extensions).
    static func parse(_ yaml: String, allowShell: Bool = false) throws -> ParsedExtension {
        // Strip the `# cai` header line
        let lines = yaml.components(separatedBy: .newlines)
        let body = lines.dropFirst().joined(separator: "\n")

        guard let dict = try Yams.load(yaml: body) as? [String: Any] else {
            throw ParseError.invalidYAML
        }

        guard let name = dict["name"] as? String, !name.isEmpty else {
            throw ParseError.missingField("name")
        }

        guard let type = dict["type"] as? String else {
            throw ParseError.missingField("type")
        }

        let icon = dict["icon"] as? String ?? "puzzlepiece.extension"
        let description = dict["description"] as? String
        let author = dict["author"] as? String

        switch type {
        case "prompt":
            return try parsePromptShortcut(dict, name: name, icon: icon, author: author, description: description)
        case "url":
            return try parseURLShortcut(dict, name: name, icon: icon, author: author, description: description)
        case "webhook":
            return try parseWebhookDestination(dict, name: name, icon: icon, author: author, description: description)
        case "deeplink":
            return try parseDeeplinkDestination(dict, name: name, icon: icon, author: author, description: description)
        case "applescript":
            throw ParseError.blockedType("AppleScript")
        case "shell":
            if allowShell {
                return try parseShellShortcut(dict, name: name, icon: icon, author: author, description: description)
            }
            throw ParseError.blockedType("Shell")
        default:
            throw ParseError.unsupportedType(type)
        }
    }

    // MARK: - Shortcut Parsers

    private static func parsePromptShortcut(_ dict: [String: Any], name: String, icon: String, author: String?, description: String?) throws -> ParsedExtension {
        guard let prompt = dict["prompt"] as? String, !prompt.isEmpty else {
            throw ParseError.missingField("prompt")
        }
        let shortcut = CaiShortcut(
            name: name,
            type: .prompt,
            value: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return .shortcut(shortcut, author: author, description: description)
    }

    private static func parseURLShortcut(_ dict: [String: Any], name: String, icon: String, author: String?, description: String?) throws -> ParsedExtension {
        guard let url = dict["url"] as? String, !url.isEmpty else {
            throw ParseError.missingField("url")
        }
        let shortcut = CaiShortcut(
            name: name,
            type: .url,
            value: url.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return .shortcut(shortcut, author: author, description: description)
    }

    private static func parseShellShortcut(_ dict: [String: Any], name: String, icon: String, author: String?, description: String?) throws -> ParsedExtension {
        guard let command = dict["shell"] as? String, !command.isEmpty else {
            throw ParseError.missingField("shell")
        }
        let shortcut = CaiShortcut(
            name: name,
            type: .shell,
            value: command.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return .shortcut(shortcut, author: author, description: description)
    }

    // MARK: - Destination Parsers

    private static func parseWebhookDestination(_ dict: [String: Any], name: String, icon: String, author: String?, description: String?) throws -> ParsedExtension {
        guard let webhookDict = dict["webhook"] as? [String: Any] else {
            throw ParseError.missingField("webhook")
        }

        guard let url = webhookDict["url"] as? String, !url.isEmpty else {
            throw ParseError.missingField("webhook.url")
        }

        guard url.lowercased().hasPrefix("https://") else {
            throw ParseError.insecureURL
        }

        let method = webhookDict["method"] as? String ?? "POST"
        let body = webhookDict["body"] as? String ?? ""
        let headers: [String: String]
        if let h = webhookDict["headers"] as? [String: String] {
            headers = h
        } else {
            headers = ["Content-Type": "application/json"]
        }

        let showInActionList = dict["show_in_action_list"] as? Bool ?? false
        let setupFields = parseSetupFields(dict["setup"] as? [[String: Any]])

        let dest = OutputDestination(
            name: name,
            icon: icon,
            type: .webhook(WebhookConfig(
                url: url,
                method: method,
                headers: headers,
                bodyTemplate: body
            )),
            isEnabled: true,
            isBuiltIn: false,
            showInActionList: showInActionList,
            setupFields: setupFields
        )
        return .destination(dest, author: author, description: description)
    }

    private static func parseDeeplinkDestination(_ dict: [String: Any], name: String, icon: String, author: String?, description: String?) throws -> ParsedExtension {
        guard let deeplink = dict["deeplink"] as? String, !deeplink.isEmpty else {
            throw ParseError.missingField("deeplink")
        }

        let showInActionList = dict["show_in_action_list"] as? Bool ?? false
        let setupFields = parseSetupFields(dict["setup"] as? [[String: Any]])

        let dest = OutputDestination(
            name: name,
            icon: icon,
            type: .deeplink(template: deeplink.trimmingCharacters(in: .whitespacesAndNewlines)),
            isEnabled: true,
            isBuiltIn: false,
            showInActionList: showInActionList,
            setupFields: setupFields
        )
        return .destination(dest, author: author, description: description)
    }

    // MARK: - Setup Fields

    private static func parseSetupFields(_ fields: [[String: Any]]?) -> [SetupField] {
        guard let fields = fields else { return [] }
        return fields.compactMap { field in
            guard let key = field["key"] as? String, !key.isEmpty else { return nil }
            let secret = field["secret"] as? Bool ?? false
            return SetupField(key: key, isSecret: secret)
        }
    }
}
