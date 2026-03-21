import Foundation

// MARK: - MCP Config Manager

/// Manages MCP server configurations and action config registry.
/// Persists server configs to ~/.config/cai/mcp-servers.json.
/// Publishes state for SwiftUI bindings (same pattern as CaiSettings).
class MCPConfigManager: ObservableObject {

    static let shared = MCPConfigManager()

    // MARK: - Published State

    /// All configured MCP servers.
    @Published var serverConfigs: [MCPServerConfig] = []

    /// Current status per server (updated via notifications from MCPClientService).
    @Published var serverStatuses: [UUID: MCPServerStatus] = [:]

    // MARK: - Config File

    private let configDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/cai", isDirectory: true)
    }()

    private var configFileURL: URL {
        configDirectory.appendingPathComponent("mcp-servers.json")
    }

    // MARK: - Init

    private init() {
        loadConfig()
        observeStatusChanges()
    }

    // MARK: - Status Observation

    private func observeStatusChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStatusChanged(_:)),
            name: .caiMCPStatusChanged,
            object: nil
        )
    }

    @objc private func handleStatusChanged(_ notification: Notification) {
        guard let configId = notification.userInfo?["configId"] as? UUID else { return }
        Task {
            let status = await MCPClientService.shared.status(for: configId)
            await MainActor.run {
                self.serverStatuses[configId] = status
            }
        }
    }

    // MARK: - Available Actions

    /// Returns MCP action configs for all connected servers whose required tools are available.
    var availableActions: [MCPActionConfig] {
        var actions: [MCPActionConfig] = []
        for config in serverConfigs where config.isEnabled {
            let status = serverStatuses[config.id]
            // Show actions when server is configured (even if disconnected — auto-connect on click)
            let configs = actionConfigs(for: config)
            actions.append(contentsOf: configs)
        }
        return actions
    }

    // MARK: - Action Config Registry

    /// Returns action configs for a given server based on its provider type.
    /// Hardcoded for known providers (GitHub, Linear). No actions for custom servers yet.
    /// Future: move to JSON file or derive from MCP tool schemas.
    func actionConfigs(for server: MCPServerConfig) -> [MCPActionConfig] {
        switch server.providerType {
        case .github:
            return [Self.githubCreateIssue(serverConfigId: server.id)]
        case .linear:
            return [Self.linearCreateIssue(serverConfigId: server.id)]
        case .custom:
            return []
        }
    }

    // MARK: - GitHub Action Configs

    static func githubCreateIssue(serverConfigId: UUID) -> MCPActionConfig {
        MCPActionConfig(
            id: "github_create_issue_\(serverConfigId.uuidString)",
            serverConfigId: serverConfigId,
            displayName: "Create GitHub Issue",
            icon: "plus.circle",
            confirmLabel: "Create Issue",
            llmPrompt: MCPLLMPrompt(
                systemPrompt: """
                Generate a concise bug ticket from the user's selected text.
                Output EXACTLY in this format (no markdown fences, no extra text):

                TITLE: <one-line title, max 80 chars>

                <detailed description — include root cause analysis if the text is a stack trace, \
                relevant context, and suggested next steps>
                """,
                titleField: "title",
                bodyField: "body"
            ),
            fields: [
                MCPFieldConfig(id: "repo", label: "Repository", type: .searchablePicker, source: .mcpPrefetch(
                    contextTool: "get_me",
                    contextPath: "login",
                    orgsTool: "get_teams",
                    searchTool: "search_repositories",
                    queryParam: "query"
                ), required: true),
                MCPFieldConfig(id: "title", label: "Title", type: .text, source: .llm, required: true),
                MCPFieldConfig(id: "body", label: "Description", type: .textarea, source: .llm, required: true),
                MCPFieldConfig(id: "labels", label: "Labels", type: .multiselect, source: .mcpDependentOn(
                    parentField: "repo",
                    toolName: "list_label",
                    argumentMapping: ["owner": "{{parent:owner}}", "repo": "{{parent:name}}"]
                )),
            ],
            submitTool: "issue_write",
            submitMapping: [
                "owner": "{{repo:owner}}",   // Splits "owner/repo" → "owner"
                "repo": "{{repo:name}}",     // Splits "owner/repo" → "repo"
                "title": "{{title}}",
                "body": "{{body}}",
                "labels": "{{labels}}",
            ],
            staticArguments: ["method": "create"],
            triageConfig: MCPTriageConfig(
                searchTool: "search_issues",
                queryField: "title",
                commentTool: "add_issue_comment",
                commentMapping: [
                    "owner": "{{repo:owner}}",
                    "repo": "{{repo:name}}",
                    "issue_number": "{{issue_id}}"
                ],
                maxResults: 3
            )
        )
    }

    // MARK: - Linear Action Configs

    static func linearCreateIssue(serverConfigId: UUID) -> MCPActionConfig {
        MCPActionConfig(
            id: "linear_create_issue_\(serverConfigId.uuidString)",
            serverConfigId: serverConfigId,
            displayName: "Create Linear Issue",
            icon: "diamond",
            confirmLabel: "Create Issue",
            llmPrompt: MCPLLMPrompt(
                systemPrompt: """
                Generate a concise ticket from the user's selected text.
                Output EXACTLY in this format (no markdown fences, no extra text):

                TITLE: <one-line title, max 80 chars>

                <detailed description — include root cause analysis if the text is a stack trace, \
                relevant context, and suggested next steps>
                """,
                titleField: "title",
                bodyField: "body"
            ),
            fields: [
                MCPFieldConfig(id: "title", label: "Title", type: .text, source: .llm, required: true),
                MCPFieldConfig(id: "body", label: "Description", type: .textarea, source: .llm, required: true),
                MCPFieldConfig(id: "team", label: "Team", type: .picker, source: .mcp(toolName: "list_teams"), required: true),
                MCPFieldConfig(id: "project", label: "Project", type: .picker, source: .mcp(toolName: "list_projects")),
                MCPFieldConfig(id: "priority", label: "Priority", type: .picker, source: .mcp(toolName: "list_priorities")),
                MCPFieldConfig(id: "labels", label: "Labels", type: .multiselect, source: .mcp(toolName: "list_labels")),
                MCPFieldConfig(id: "assignee", label: "Assignee", type: .picker, source: .mcp(toolName: "list_assignees")),
            ],
            submitTool: "create_issue",
            submitMapping: [
                "teamId": "{{team}}",
                "projectId": "{{project}}",
                "title": "{{title}}",
                "description": "{{body}}",
                "priority": "{{priority}}",
                "labelIds": "{{labels}}",
                "assigneeId": "{{assignee}}",
            ],
            triageConfig: MCPTriageConfig(
                searchTool: "search_issues",
                queryField: "title",
                commentTool: nil,  // Linear MCP may not support adding comments
                maxResults: 3
            )
        )
    }

    // MARK: - Config Persistence

    func loadConfig() {
        // Create config directory if needed
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        // If config file doesn't exist, create default with GitHub + Linear templates
        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            createDefaultConfig()
            return
        }

        guard let data = try? Data(contentsOf: configFileURL),
              let configFile = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else {
            createDefaultConfig()
            return
        }

        var needsSave = false
        serverConfigs = configFile.mcpServers.map { (key, json) in
            let transport: MCPTransport
            if json.transport.type == "remote", let url = json.transport.url {
                transport = .remote(url: url)
            } else {
                transport = .remote(url: "")
            }

            let authType: MCPAuthType = MCPAuthType(rawValue: json.auth?.type ?? "none") ?? .none

            // Use persisted UUID, or migrate old configs without an id field
            let id: UUID
            if let stored = UUID(uuidString: json.id) {
                id = stored
            } else {
                id = UUID()
                needsSave = true // Re-save to persist the generated UUID
            }

            // Use persisted providerType, or infer from name for old configs
            let providerType: MCPProviderType
            if let stored = json.providerType, let type = MCPProviderType(rawValue: stored) {
                providerType = type
            } else {
                providerType = Self.inferProviderType(from: key)
                needsSave = true
            }

            return MCPServerConfig(
                id: id,
                name: key,
                providerType: providerType,
                transport: transport,
                authType: authType,
                authKeychainKey: json.auth?.keychainKey,
                isEnabled: true,
                icon: iconForServer(providerType),
                autoConnect: false,
                headers: json.headers ?? [:]
            )
        }

        // Re-save to persist migrated UUIDs/providerTypes
        if needsSave { saveConfig() }
    }

    func saveConfig() {
        var servers: [String: MCPConfigFile.MCPServerConfigJSON] = [:]

        for config in serverConfigs {
            // Use name as key, dedup by appending UUID suffix if name already taken
            var key = config.name
            if servers[key] != nil {
                key = "\(config.name)_\(config.id.uuidString.prefix(8))"
            }

            let transportJSON: MCPConfigFile.MCPServerConfigJSON.TransportJSON
            switch config.transport {
            case .remote(let url):
                transportJSON = .init(type: "remote", url: url)
            }

            let authJSON: MCPConfigFile.MCPServerConfigJSON.AuthJSON? = config.authType != .none
                ? .init(type: config.authType.rawValue, keychainKey: config.authKeychainKey)
                : nil

            servers[key] = MCPConfigFile.MCPServerConfigJSON(
                id: config.id.uuidString,
                providerType: config.providerType.rawValue,
                transport: transportJSON,
                auth: authJSON,
                headers: config.headers.isEmpty ? nil : config.headers
            )
        }

        let configFile = MCPConfigFile(mcpServers: servers)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(configFile) {
            try? data.write(to: configFileURL, options: .atomic)
        }
    }

    // MARK: - Server Management

    func addServer(_ config: MCPServerConfig) {
        serverConfigs.append(config)
        saveConfig()
    }

    func removeServer(id: UUID) {
        serverConfigs.removeAll { $0.id == id }
        Task {
            await MCPClientService.shared.disconnect(configId: id)
        }
        saveConfig()
    }

    func updateServer(_ config: MCPServerConfig) {
        if let index = serverConfigs.firstIndex(where: { $0.id == config.id }) {
            serverConfigs[index] = config
            saveConfig()
        }
    }

    // MARK: - Auto-Connect

    /// Connects all servers that have autoConnect enabled. Called from AppDelegate on launch.
    func autoConnectServers() {
        for config in serverConfigs where config.autoConnect && config.isEnabled {
            // Only auto-connect if auth is configured
            if config.authType == .bearerToken,
               let key = config.authKeychainKey,
               KeychainHelper.get(forKey: key) == nil {
                continue
            }
            Task {
                try? await MCPClientService.shared.connect(config: config)
            }
        }
    }

    // MARK: - Private Helpers

    private func createDefaultConfig() {
        let githubId = UUID()
        let linearId = UUID()

        serverConfigs = [
            MCPServerConfig(
                id: githubId,
                name: "GitHub",
                providerType: .github,
                transport: .remote(url: "https://api.githubcopilot.com/mcp/"),
                authType: .bearerToken,
                authKeychainKey: "mcp_github_pat",
                isEnabled: true,
                icon: "plus.circle",
                autoConnect: false,
                headers: ["X-MCP-Toolsets": "issues,repos,labels,context"]
            ),
            MCPServerConfig(
                id: linearId,
                name: "Linear",
                providerType: .linear,
                transport: .remote(url: "https://mcp.linear.app/mcp"),
                authType: .bearerToken,
                authKeychainKey: "mcp_linear_apikey",
                isEnabled: true,
                icon: "diamond",
                autoConnect: false
            ),
        ]

        saveConfig()
    }

    /// Infers provider type from server name (for migrating old configs without providerType).
    static func inferProviderType(from name: String) -> MCPProviderType {
        let lower = name.lowercased()
        if lower.contains("github") { return .github }
        if lower.contains("linear") { return .linear }
        return .custom
    }

    private func iconForServer(_ providerType: MCPProviderType) -> String {
        switch providerType {
        case .github: return "plus.circle"
        case .linear: return "diamond"
        case .custom: return "puzzlepiece.extension"
        }
    }
}
