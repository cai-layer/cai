import Foundation

// MARK: - MCP Provider Type

/// Known MCP provider types. Used for action config dispatch instead of fragile name matching.
enum MCPProviderType: String, Codable, Equatable {
    case github
    case linear
    case custom                         // User-added servers with no built-in action config
}

// MARK: - MCP Server Configuration

/// Configuration for a remote MCP server connection.
/// Stored in ~/.config/cai/mcp-servers.json. Secrets live in Keychain, never in this file.
struct MCPServerConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String                    // "GitHub", "Linear"
    var providerType: MCPProviderType   // Determines action config dispatch
    var transport: MCPTransport
    var authType: MCPAuthType
    var authKeychainKey: String?        // Keychain key for token: "mcp_github_pat"
    var isEnabled: Bool
    var icon: String                    // SF Symbol name
    var autoConnect: Bool               // Connect on app launch
    var headers: [String: String]       // Extra headers: e.g. "X-MCP-Toolsets": "issues"

    init(
        id: UUID = UUID(),
        name: String,
        providerType: MCPProviderType = .custom,
        transport: MCPTransport,
        authType: MCPAuthType = .none,
        authKeychainKey: String? = nil,
        isEnabled: Bool = true,
        icon: String = "puzzlepiece.extension",
        autoConnect: Bool = false,
        headers: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.providerType = providerType
        self.transport = transport
        self.authType = authType
        self.authKeychainKey = authKeychainKey
        self.isEnabled = isEnabled
        self.icon = icon
        self.autoConnect = autoConnect
        self.headers = headers
    }
}

// MARK: - Transport

enum MCPTransport: Codable, Equatable {
    case remote(url: String)            // HTTP/SSE endpoint
    // case stdio(command: String, args: [String], env: [String: String])  // future

    var url: String? {
        switch self {
        case .remote(let url): return url
        }
    }
}

// MARK: - Auth

enum MCPAuthType: String, Codable, Equatable {
    case bearerToken                    // PAT / API key in Authorization header
    case none
}

// MARK: - Server Status

enum MCPServerStatus: Equatable {
    case disconnected
    case connecting
    case connected(toolCount: Int)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected(let count): return "Connected — \(count) tools"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

// MARK: - MCP Action Configuration (Declarative)

/// Describes a single MCP-powered action (e.g., "Create GitHub Issue", "Send to Slack").
/// The MCPFormView renders these generically — no provider-specific UI code needed.
struct MCPActionConfig: Identifiable {
    let id: String                      // "github_create_issue"
    let serverConfigId: UUID            // Which MCP server to use
    let displayName: String             // "Create GitHub Issue"
    let icon: String                    // SF Symbol: "plus.circle"
    let confirmLabel: String            // "Create Issue" / "Send Message"
    let llmPrompt: MCPLLMPrompt?        // Optional LLM generation for text fields
    let fields: [MCPFieldConfig]        // Ordered list of form fields
    let submitTool: String              // MCP tool to call on confirm: "issue_write"
    let submitMapping: [String: String] // Maps field keys to tool params: "title": "{{title}}"
    var staticArguments: [String: String] // Always-sent params: "method": "create"
    let triageConfig: MCPTriageConfig?  // Optional duplicate detection config

    init(
        id: String,
        serverConfigId: UUID,
        displayName: String,
        icon: String,
        confirmLabel: String,
        llmPrompt: MCPLLMPrompt?,
        fields: [MCPFieldConfig],
        submitTool: String,
        submitMapping: [String: String],
        staticArguments: [String: String] = [:],
        triageConfig: MCPTriageConfig? = nil
    ) {
        self.id = id
        self.serverConfigId = serverConfigId
        self.displayName = displayName
        self.icon = icon
        self.confirmLabel = confirmLabel
        self.llmPrompt = llmPrompt
        self.fields = fields
        self.submitTool = submitTool
        self.submitMapping = submitMapping
        self.staticArguments = staticArguments
        self.triageConfig = triageConfig
    }
}

/// LLM prompt configuration for auto-generating field values.
struct MCPLLMPrompt {
    let systemPrompt: String            // Instructions for the LLM
    let titleField: String              // Which field to populate with generated title
    let bodyField: String?              // Which field to populate with generated body
}

// MARK: - Triage Configuration

/// Describes how to search for similar/duplicate issues before creating a new one.
/// Used by MCPFormView to show an inline "N similar issues" hint below the title field.
struct MCPTriageConfig {
    let searchTool: String              // MCP tool to search: "search_issues"
    let queryField: String              // Which form field to use as search query: "title"
    let scopeField: String?             // Form field that scopes the search: "repo" (GitHub) or "team" (Linear)
    let commentTool: String?            // Tool to add comment to existing issue (nil = info-only)
    let commentMapping: [String: String] // Maps tool params for commenting: "issue_number": "{{issue_id}}"
    let searchArgumentMapping: [String: String] // Extra args for search tool: ["teamId": "{{scope}}"]
    let maxResults: Int                 // Cap displayed results (default: 3)

    init(
        searchTool: String,
        queryField: String,
        scopeField: String? = nil,
        commentTool: String? = nil,
        commentMapping: [String: String] = [:],
        searchArgumentMapping: [String: String] = [:],
        maxResults: Int = 3
    ) {
        self.searchTool = searchTool
        self.queryField = queryField
        self.scopeField = scopeField
        self.commentTool = commentTool
        self.commentMapping = commentMapping
        self.searchArgumentMapping = searchArgumentMapping
        self.maxResults = maxResults
    }
}

/// A single triage result — a potentially duplicate issue found via search.
struct MCPTriageResult: Identifiable {
    let id: String                      // Issue number or ID
    let title: String                   // Issue title
    let url: String?                    // Link to the issue (for "View" action)
}

// MARK: - Field Configuration

/// A single form field in an MCP action form.
struct MCPFieldConfig: Identifiable {
    let id: String                      // "repo", "labels", "team"
    let label: String                   // "Repository", "Labels"
    let type: MCPFieldType
    let source: MCPFieldSource
    let required: Bool
    let pickerIdKey: String?            // Override which JSON key to use as picker option ID (e.g. "name" for GitHub labels)

    init(
        id: String,
        label: String,
        type: MCPFieldType,
        source: MCPFieldSource,
        required: Bool = false,
        pickerIdKey: String? = nil
    ) {
        self.id = id
        self.label = label
        self.pickerIdKey = pickerIdKey
        self.type = type
        self.source = source
        self.required = required
    }
}

enum MCPFieldType: String {
    case text                           // Single-line TextField
    case textarea                       // Multi-line TextEditor
    case picker                         // Dropdown (single select)
    case multiselect                    // Toggleable chips (multi select)
    case searchablePicker               // Type-to-search with dropdown results
}

enum MCPFieldSource {
    case userInput                      // User types freely
    case llm                           // LLM generates initial value, user can edit
    case staticOptions([MCPPickerOption]) // Fixed options (e.g., priority levels 0-4)
    case mcp(toolName: String)          // Options fetched via MCP tool call
    case mcpPrefetch(                   // Pre-fetch all options on init, filter locally on type
        contextTool: String,            // Tool to get user info: "get_me"
        contextPath: String,            // JSON key: "login"
        orgsTool: String?,              // Tool to get orgs: "get_teams" (nil = skip)
        searchTool: String,             // Tool to search: "search_repositories"
        queryParam: String              // Param name: "query"
    )
    case mcpDependentOn(               // Fetches options when a parent field value changes
        parentField: String,            // Field id to watch: "repo"
        toolName: String,               // Tool to call: "list_labels"
        argumentMapping: [String: String] // Maps tool params to parent value parts: "owner": "{{parent:owner}}"
    )
}

// MARK: - Picker Option

/// A single option in a picker or multiselect field, fetched from MCP.
struct MCPPickerOption: Identifiable, Equatable {
    let id: String                      // Unique value to submit
    let label: String                   // Display text
}

// MARK: - Metadata Cache

/// Caches MCP-fetched metadata (repos, labels, teams, etc.) to avoid re-fetching on every action.
struct MCPMetadataCache {
    var entries: [String: CacheEntry] = [:]  // Keyed by "serverConfigId_toolName"

    struct CacheEntry {
        let options: [MCPPickerOption]
        let fetchedAt: Date
        let ttl: TimeInterval

        var isExpired: Bool {
            Date().timeIntervalSince(fetchedAt) > ttl
        }
    }

    /// Default TTL: 5 minutes.
    static let defaultTTL: TimeInterval = 300

    /// Returns cached options if valid, nil if expired or missing.
    func get(serverConfigId: UUID, toolName: String) -> [MCPPickerOption]? {
        let key = "\(serverConfigId.uuidString)_\(toolName)"
        guard let entry = entries[key], !entry.isExpired else { return nil }
        return entry.options
    }

    /// Stores options in cache.
    mutating func set(serverConfigId: UUID, toolName: String, options: [MCPPickerOption], ttl: TimeInterval = MCPMetadataCache.defaultTTL) {
        let key = "\(serverConfigId.uuidString)_\(toolName)"
        entries[key] = CacheEntry(options: options, fetchedAt: Date(), ttl: ttl)
    }

    /// Clears all entries for a server.
    mutating func clear(serverConfigId: UUID) {
        entries = entries.filter { !$0.key.hasPrefix(serverConfigId.uuidString) }
    }
}

// MARK: - Errors

enum MCPError: LocalizedError {
    case notConnected(String)
    case connectionFailed(String)
    case connectionTimeout
    case toolCallFailed(String)
    case toolNotFound(String)
    case authMissing(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConnected(let server): return "\(server) is not connected"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .connectionTimeout: return "Connection timed out"
        case .toolCallFailed(let msg): return "Tool call failed: \(msg)"
        case .toolNotFound(let name): return "Tool '\(name)' not found"
        case .authMissing(let server): return "No API key configured for \(server)"
        case .invalidResponse: return "Invalid response from server"
        }
    }
}

// MARK: - Config File

/// Container for the JSON config file at ~/.config/cai/mcp-servers.json
struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfigJSON]

    struct MCPServerConfigJSON: Codable {
        var id: String                  // Persisted UUID string — stable across launches
        var providerType: String?       // "github", "linear", "custom" (nil → infer from name)
        var transport: TransportJSON
        var auth: AuthJSON?
        var headers: [String: String]?

        struct TransportJSON: Codable {
            var type: String            // "remote"
            var url: String?
        }

        struct AuthJSON: Codable {
            var type: String            // "bearerToken", "none"
            var keychainKey: String?
        }
    }
}
