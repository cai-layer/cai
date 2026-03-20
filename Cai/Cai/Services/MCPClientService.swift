import Foundation
import MCP

// MARK: - MCP Client Service

/// Manages connections to remote MCP servers (HTTP/SSE transport).
/// Handles tool discovery, tool calls, and metadata caching.
/// Follows the actor pattern used by LLMService, BuiltInLLM, OutputDestinationService.
actor MCPClientService {

    static let shared = MCPClientService()

    // MARK: - Connection State

    private struct MCPConnection {
        let config: MCPServerConfig
        let client: Client
        let transport: any Transport
        var tools: [Tool]
    }

    /// Active connections keyed by server config ID.
    private var connections: [UUID: MCPConnection] = [:]

    /// Status per server (includes disconnected/error states).
    private var statuses: [UUID: MCPServerStatus] = [:]

    /// Metadata cache for picker options.
    private var metadataCache = MCPMetadataCache()

    /// Connection timeout.
    private let connectionTimeout: TimeInterval = 10

    // MARK: - Connect

    /// Connects to an MCP server. Creates HTTP transport, initializes client, discovers tools.
    func connect(config: MCPServerConfig) async throws {
        // Don't reconnect if already connected
        if let existing = connections[config.id], statuses[config.id]?.isConnected == true {
            return
        }

        setStatus(config.id, .connecting)

        do {
            let transport = try createTransport(for: config)
            let client = Client(name: "Cai", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")

            // Connect with timeout
            try await withTimeout(seconds: connectionTimeout) {
                _ = try await client.connect(transport: transport)
            }

            // Discover available tools
            let toolsResult = try await client.listTools()
            let tools = toolsResult.tools

            connections[config.id] = MCPConnection(
                config: config,
                client: client,
                transport: transport,
                tools: tools
            )

            setStatus(config.id, .connected(toolCount: tools.count))

        } catch {
            setStatus(config.id, .error(error.localizedDescription))
            throw MCPError.connectionFailed(error.localizedDescription)
        }
    }

    // MARK: - Disconnect

    /// Disconnects a single server.
    func disconnect(configId: UUID) async {
        if let connection = connections[configId] {
            await connection.client.disconnect()
            connections.removeValue(forKey: configId)
        }
        metadataCache.clear(serverConfigId: configId)
        setStatus(configId, .disconnected)
    }

    /// Disconnects all servers. Called from AppDelegate.applicationWillTerminate().
    func disconnectAll() async {
        for (id, connection) in connections {
            await connection.client.disconnect()
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
    func availableTools(for configId: UUID) -> [Tool] {
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
        arguments: [String: Value]
    ) async throws -> String {
        guard let connection = connections[serverConfigId] else {
            let name = statuses[serverConfigId] != nil ? "Server" : "Unknown server"
            throw MCPError.notConnected(name)
        }

        guard connection.tools.contains(where: { $0.name == toolName }) else {
            throw MCPError.toolNotFound(toolName)
        }

        let result = try await connection.client.callTool(name: toolName, arguments: arguments)

        // Extract text content from the response
        let textParts = result.content.compactMap { content -> String? in
            if case .text(let text) = content {
                return text
            }
            return nil
        }

        if textParts.isEmpty {
            throw MCPError.invalidResponse
        }

        return textParts.joined(separator: "\n")
    }

    // MARK: - Metadata (Cached)

    /// Fetches picker options for a field via MCP tool call, with caching.
    func fetchOptions(
        serverConfigId: UUID,
        toolName: String,
        arguments: [String: Value] = [:]
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

    private func createTransport(for config: MCPServerConfig) throws -> any Transport {
        switch config.transport {
        case .remote(let urlString):
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

            return HTTPClientTransport(
                endpoint: url,
                requestModifier: { request in
                    var req = request
                    // Inject auth
                    if let token = authToken {
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    // Inject extra headers (e.g., X-MCP-Toolsets)
                    for (key, value) in extraHeaders {
                        req.setValue(value, forHTTPHeaderField: key)
                    }
                    return req
                }
            )
        }
    }

    private func setStatus(_ configId: UUID, _ status: MCPServerStatus) {
        statuses[configId] = status
        // Post notification for UI updates (MCPConfigManager observes this)
        Task { @MainActor in
            NotificationCenter.default.post(name: .caiMCPStatusChanged, object: nil, userInfo: ["configId": configId])
        }
    }

    /// Parses tool response JSON into picker options.
    /// Handles common patterns: arrays of objects with id/name, arrays of strings, etc.
    private func parsePickerOptions(from jsonText: String, toolName: String) -> [MCPPickerOption] {
        guard let data = jsonText.data(using: .utf8) else { return [] }

        // Try parsing as JSON
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            // Fallback: treat each line as an option
            return jsonText.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { MCPPickerOption(id: $0, label: $0) }
        }

        // Array of objects with id/name or name/full_name
        if let array = json as? [[String: Any]] {
            return array.compactMap { obj in
                let id = (obj["id"] as? String)
                    ?? (obj["id"] as? Int).map(String.init)
                    ?? (obj["full_name"] as? String)
                    ?? (obj["name"] as? String)
                let label = (obj["name"] as? String)
                    ?? (obj["full_name"] as? String)
                    ?? (obj["title"] as? String)
                    ?? (obj["label"] as? String)
                guard let id = id, let label = label else { return nil }
                return MCPPickerOption(id: id, label: label)
            }
        }

        // Array of strings
        if let array = json as? [String] {
            return array.map { MCPPickerOption(id: $0, label: $0) }
        }

        return []
    }

    /// Runs an async operation with a timeout.
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MCPError.connectionTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
