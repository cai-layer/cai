import Foundation

// MARK: - MCP Client Service

/// Manages connections to remote MCP servers via the thin MCPTransportClient.
/// Handles tool discovery, tool calls, and metadata caching.
/// Follows the actor pattern used by LLMService, BuiltInLLM, OutputDestinationService.
actor MCPClientService {

    static let shared = MCPClientService()

    // MARK: - Connection State

    private struct MCPConnection {
        let config: MCPServerConfig
        let client: MCPTransportClient
        var tools: [MCPToolInfo]
    }

    /// Active connections keyed by server config ID.
    private var connections: [UUID: MCPConnection] = [:]

    /// Status per server (includes disconnected/error states).
    private var statuses: [UUID: MCPServerStatus] = [:]

    /// Metadata cache for picker options.
    private var metadataCache = MCPMetadataCache()

    // MARK: - Connect

    /// Connects to an MCP server. Creates transport client, initializes, discovers tools.
    func connect(config: MCPServerConfig) async throws {
        // Don't reconnect if already connected
        if connections[config.id] != nil, statuses[config.id]?.isConnected == true {
            return
        }

        setStatus(config.id, .connecting)

        do {
            let client = try createClient(for: config)

            // Initialize (handshake + notifications/initialized)
            try await client.initialize()

            // Discover available tools
            let tools = try await client.listTools()

            connections[config.id] = MCPConnection(
                config: config,
                client: client,
                tools: tools
            )

            print("🔌 MCP \(config.name) connected — \(tools.count) tools: \(tools.map { $0.name }.joined(separator: ", "))")
            setStatus(config.id, .connected(toolCount: tools.count))

        } catch let mcpError as MCPError {
            setStatus(config.id, .error(mcpError.localizedDescription))
            throw mcpError
        } catch {
            let wrapped = MCPError.connectionFailed(error.localizedDescription)
            setStatus(config.id, .error(error.localizedDescription))
            throw wrapped
        }
    }

    // MARK: - Disconnect

    /// Disconnects a single server.
    func disconnect(configId: UUID) async {
        if let connection = connections[configId] {
            connection.client.disconnect()
            connections.removeValue(forKey: configId)
        }
        metadataCache.clear(serverConfigId: configId)
        setStatus(configId, .disconnected)
    }

    /// Disconnects all servers. Called from AppDelegate.applicationWillTerminate().
    func disconnectAll() async {
        for (id, connection) in connections {
            connection.client.disconnect()
            setStatus(id, .disconnected)
        }
        connections.removeAll()
    }

    // MARK: - Status

    /// Returns the current status for a server.
    func status(for configId: UUID) -> MCPServerStatus {
        statuses[configId] ?? .disconnected
    }

    /// Returns all server statuses (for UI binding).
    func allStatuses() -> [UUID: MCPServerStatus] {
        statuses
    }

    // MARK: - Tool Discovery

    /// Returns available tools for a connected server.
    func availableTools(for configId: UUID) -> [MCPToolInfo] {
        connections[configId]?.tools ?? []
    }

    /// Checks if a server has a specific tool.
    func hasTool(serverConfigId: UUID, toolName: String) -> Bool {
        connections[serverConfigId]?.tools.contains(where: { $0.name == toolName }) ?? false
    }

    // MARK: - Tool Calls

    /// Calls a tool on a connected MCP server.
    /// Returns the text content from the tool response.
    func callTool(
        serverConfigId: UUID,
        toolName: String,
        arguments: [String: Any]
    ) async throws -> String {
        guard let connection = connections[serverConfigId] else {
            let name = statuses[serverConfigId] != nil ? "Server" : "Unknown server"
            throw MCPError.notConnected(name)
        }

        guard connection.tools.contains(where: { $0.name == toolName }) else {
            throw MCPError.toolNotFound(toolName)
        }

        let result = try await connection.client.callTool(name: toolName, arguments: arguments)
        return result.text
    }

    // MARK: - Metadata (Cached)

    /// Fetches picker options for a field via MCP tool call, with caching.
    func fetchOptions(
        serverConfigId: UUID,
        toolName: String,
        arguments: [String: Any] = [:]
    ) async throws -> [MCPPickerOption] {
        // Check cache first
        if let cached = metadataCache.get(serverConfigId: serverConfigId, toolName: toolName) {
            return cached
        }

        // Fetch from MCP
        let responseText = try await callTool(
            serverConfigId: serverConfigId,
            toolName: toolName,
            arguments: arguments
        )

        // Parse JSON response into picker options
        let options = parsePickerOptions(from: responseText, toolName: toolName)

        // Cache the result
        metadataCache.set(serverConfigId: serverConfigId, toolName: toolName, options: options)

        return options
    }

    // MARK: - Auto-Connect

    /// Ensures a server is connected, attempting auto-connect if needed.
    /// Used when user clicks an MCP action and the server is disconnected.
    func ensureConnected(config: MCPServerConfig) async throws {
        if let status = statuses[config.id], status.isConnected {
            return
        }
        try await connect(config: config)
    }

    // MARK: - Private Helpers

    private func createClient(for config: MCPServerConfig) throws -> MCPTransportClient {
        let urlString: String
        switch config.transport {
        case .remote(let url): urlString = url
        }

        guard let url = URL(string: urlString) else {
            throw MCPError.connectionFailed("Invalid URL: \(urlString)")
        }

        // Resolve auth token from Keychain
        var authToken: String?
        if config.authType == .bearerToken, let keychainKey = config.authKeychainKey {
            authToken = KeychainHelper.get(forKey: keychainKey)
            if authToken == nil || authToken?.isEmpty == true {
                throw MCPError.authMissing(config.name)
            }
        }

        let extraHeaders = config.headers

        return MCPTransportClient(
            endpoint: url,
            requestModifier: { request in
                var req = request
                if let token = authToken {
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                for (key, value) in extraHeaders {
                    req.setValue(value, forHTTPHeaderField: key)
                }
                return req
            }
        )
    }

    private func setStatus(_ configId: UUID, _ status: MCPServerStatus) {
        statuses[configId] = status
        // Post notification for UI updates (MCPServerConfigManager observes this)
        Task { @MainActor in
            NotificationCenter.default.post(name: .caiMCPStatusChanged, object: nil, userInfo: ["configId": configId])
        }
    }

    /// Parses tool response JSON into picker options.
    /// Handles common patterns: arrays of objects with id/name, arrays of strings, etc.
    nonisolated func parsePickerOptions(from jsonText: String, toolName: String, idKey: String? = nil) -> [MCPPickerOption] {
        guard let data = jsonText.data(using: .utf8) else { return [] }

        // Try parsing as JSON
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            // Fallback: treat each line as an option
            return jsonText.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { MCPPickerOption(id: $0, label: $0) }
        }

        // Unwrap: bare array [...] or dict with a single array value {"labels": [...], ...}
        var rootArray: [[String: Any]]?

        if let array = json as? [[String: Any]] {
            rootArray = array
        } else if let dict = json as? [String: Any] {
            // Auto-unwrap: find the first value that is an array of objects
            for (_, value) in dict {
                if let nested = value as? [[String: Any]] {
                    rootArray = nested
                    break
                }
            }
        }

        if let array = rootArray {
            let options = array.compactMap { obj -> MCPPickerOption? in
                // ID strategy:
                // - If `idKey` override is set (e.g. "name" for GitHub labels), use that key
                // - If `full_name` exists (e.g. GitHub "owner/repo"), use it (supports template splitting)
                // - Otherwise prefer `id` (UUID) for APIs that expect IDs (e.g. Linear teamId)
                // - Fallback to `name`
                let id: String?
                if let idKey = idKey, let overrideValue = obj[idKey] as? String {
                    id = overrideValue
                } else if let fullName = obj["full_name"] as? String {
                    id = fullName
                } else {
                    id = (obj["id"] as? String)
                        ?? (obj["id"] as? Int).map(String.init)
                        ?? (obj["name"] as? String)
                }
                // Label: prefer human-readable name for display
                let label = (obj["full_name"] as? String)
                    ?? (obj["name"] as? String)
                    ?? (obj["title"] as? String)
                    ?? (obj["label"] as? String)
                guard let id = id, let label = label else { return nil }
                return MCPPickerOption(id: id, label: label)
            }
            if !options.isEmpty { return options }
        }

        // Array of strings
        if let array = json as? [String] {
            return array.map { MCPPickerOption(id: $0, label: $0) }
        }

        print("⚠️ MCP parsePickerOptions: unrecognized format for \(toolName): \(String(jsonText.prefix(200)))")
        return []
    }
}
