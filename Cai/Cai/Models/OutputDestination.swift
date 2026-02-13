import Foundation

// MARK: - Output Destination Model

/// An output destination defines where to send text after processing.
/// Built-in destinations (Mail, Notes, Reminders) work zero-config.
/// Custom destinations use webhooks, URL schemes, or shell commands.
struct OutputDestination: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var icon: String                    // SF Symbol name
    var type: DestinationType
    var isEnabled: Bool
    var isBuiltIn: Bool                 // true for Mail, Notes, Reminders
    var showInActionList: Bool          // also show as direct-route action (no LLM step)
    var setupFields: [SetupField]       // user-configurable values (API keys, etc.)

    init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        type: DestinationType,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        showInActionList: Bool = false,
        setupFields: [SetupField] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.type = type
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.showInActionList = showInActionList
        self.setupFields = setupFields
    }

    /// Whether all required setup fields have values
    var isConfigured: Bool {
        setupFields.allSatisfy { !$0.value.isEmpty }
    }
}

// MARK: - Destination Type

enum DestinationType: Codable, Equatable {
    case applescript(template: String)
    case webhook(WebhookConfig)
    case urlScheme(template: String)
    case shell(command: String)

    var label: String {
        switch self {
        case .applescript: return "AppleScript"
        case .webhook: return "Webhook"
        case .urlScheme: return "URL Scheme"
        case .shell: return "Shell Command"
        }
    }

    /// String tag for Codable and picker identification
    var tag: String {
        switch self {
        case .applescript: return "applescript"
        case .webhook: return "webhook"
        case .urlScheme: return "urlScheme"
        case .shell: return "shell"
        }
    }
}

// MARK: - Webhook Config

struct WebhookConfig: Codable, Equatable {
    var url: String
    var method: String                  // "POST", "PUT", etc.
    var headers: [String: String]
    var bodyTemplate: String            // JSON string with {{result}} placeholder

    init(
        url: String,
        method: String = "POST",
        headers: [String: String] = ["Content-Type": "application/json"],
        bodyTemplate: String
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.bodyTemplate = bodyTemplate
    }
}

// MARK: - Setup Field

/// A user-configurable field like an API key or webhook URL.
/// Stored locally; resolved at execution time via {{key}} placeholders.
struct SetupField: Codable, Identifiable, Equatable {
    let id: UUID
    var key: String                     // placeholder key, e.g. "api_key"
    var value: String                   // user-provided value
    var isSecret: Bool                  // mask in UI

    init(
        id: UUID = UUID(),
        key: String,
        value: String = "",
        isSecret: Bool = false
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.isSecret = isSecret
    }
}

// MARK: - Errors

enum OutputDestinationError: LocalizedError {
    case appleScriptFailed(String)
    case webhookFailed(Int, String)
    case invalidURL
    case shellFailed(Int, String)
    case notConfigured(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let msg):
            return "AppleScript error: \(msg)"
        case .webhookFailed(let code, let msg):
            return "Webhook failed (\(code)): \(msg)"
        case .invalidURL:
            return "Invalid URL"
        case .shellFailed(let code, let msg):
            return "Command failed (\(code)): \(msg)"
        case .notConfigured(let field):
            return "Missing setup: \(field)"
        case .timeout:
            return "Operation timed out"
        }
    }
}
