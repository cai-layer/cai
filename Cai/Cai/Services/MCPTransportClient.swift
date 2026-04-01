import Foundation

// MARK: - Thin MCP Client

/// Lightweight MCP client — speaks JSON-RPC 2.0 over HTTP.
/// Zero external dependencies: URLSession + JSONSerialization only.
/// Replaces the full modelcontextprotocol/swift-sdk with ~200 lines.
class MCPTransportClient {

    let endpoint: URL
    let requestModifier: ((URLRequest) -> URLRequest)?

    private let session: URLSession
    private let requestIdLock = NSLock()
    private var _requestId: Int = 0
    private var sessionId: String?

    /// Thread-safe incrementing request ID for JSON-RPC messages.
    private var nextRequestId: Int {
        requestIdLock.lock()
        defer { requestIdLock.unlock() }
        _requestId += 1
        return _requestId
    }

    init(endpoint: URL, requestModifier: ((URLRequest) -> URLRequest)? = nil) {
        self.endpoint = endpoint
        self.requestModifier = requestModifier
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - MCP Protocol

    /// Sends `initialize` handshake. Must be called before `listTools` or `callTool`.
    func initialize() async throws {
        let params: [String: Any] = [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "Cai",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            ]
        ]
        let response = try await post(method: "initialize", params: params)

        // Capture session ID from response if present (used by some servers)
        if let result = response["result"] as? [String: Any],
           let sid = result["sessionId"] as? String {
            sessionId = sid
        }

        // Send initialized notification (no response expected, but spec requires it)
        try await post(method: "notifications/initialized", params: [:], expectResponse: false)
    }

    /// Discovers available tools from the server.
    func listTools() async throws -> [MCPToolInfo] {
        let response = try await post(method: "tools/list", params: [:])

        guard let result = response["result"] as? [String: Any],
              let toolsArray = result["tools"] as? [[String: Any]] else {
            throw MCPError.invalidResponse
        }

        return toolsArray.map { dict in
            MCPToolInfo(
                name: dict["name"] as? String ?? "",
                description: dict["description"] as? String
            )
        }
    }

    /// Calls a tool on the server.
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments
        ]
        let response = try await post(method: "tools/call", params: params)

        guard let result = response["result"] as? [String: Any] else {
            // Check for JSON-RPC error
            if let error = response["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown error"
                throw MCPError.toolCallFailed(message)
            }
            throw MCPError.invalidResponse
        }

        // Extract text from content array
        let contentArray = result["content"] as? [[String: Any]] ?? []
        let textParts = contentArray.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }

        if textParts.isEmpty {
            throw MCPError.invalidResponse
        }

        let text = textParts.joined(separator: "\n")
        let isError = result["isError"] as? Bool ?? false

        if isError {
            throw MCPError.toolCallFailed(text)
        }

        return MCPToolResult(text: text, isError: false, raw: result)
    }

    /// Disconnects by invalidating the URL session.
    func disconnect() {
        session.invalidateAndCancel()
    }

    // MARK: - JSON-RPC Transport

    @discardableResult
    private func post(method: String, params: [String: Any], expectResponse: Bool = true) async throws -> [String: Any] {
        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]

        // Notifications (no response expected) don't have an id per JSON-RPC spec
        if expectResponse {
            body["id"] = nextRequestId
        }

        if !params.isEmpty {
            body["params"] = params
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sid = sessionId {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = jsonData

        // Apply auth + custom headers
        if let modifier = requestModifier {
            request = modifier(request)
        }

        // Retry loop: 2 base retries (3 total attempts) for transient failures.
        // 429 gets one dedicated retry outside the base budget.
        let maxRetries = 2
        let retryDelays: [UInt64] = [1_000_000_000, 3_000_000_000] // 1s, 3s
        var lastError: MCPError = .connectionFailed("Request failed")
        var did429Retry = false

        for attempt in 0...maxRetries {
            // Wait before retrying (not on first attempt)
            if attempt > 0 {
                try await Task.sleep(nanoseconds: retryDelays[attempt - 1])
            }

            let data: Data
            let urlResponse: URLResponse
            do {
                (data, urlResponse) = try await session.data(for: request)
            } catch let error as URLError where error.code == .timedOut {
                lastError = .connectionTimeout
                continue // retry on timeout
            } catch let urlError as URLError {
                lastError = .connectionFailed(urlError.localizedDescription)
                continue // retry on network errors
            } catch {
                throw MCPError.connectionFailed(error.localizedDescription)
            }

            // Capture session ID from response header
            if let httpResponse = urlResponse as? HTTPURLResponse {
                if let sid = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id"), sessionId == nil {
                    sessionId = sid
                }

                switch httpResponse.statusCode {
                case 200...299:
                    break // success — fall through to response parsing

                case 429:
                    // Rate limit: one dedicated retry with Retry-After header
                    if !did429Retry {
                        did429Retry = true
                        let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After")
                        let retryAfterSecs = UInt64(retryAfterStr.flatMap { Int($0) } ?? 5)
                        try await Task.sleep(nanoseconds: retryAfterSecs * 1_000_000_000)
                        continue
                    }
                    throw MCPError.connectionFailed("Rate limited — try again shortly")

                case 401, 403:
                    throw MCPError.authMissing("Server returned \(httpResponse.statusCode)")

                case 502, 503, 504:
                    let bodyText = String(data: data, encoding: .utf8) ?? ""
                    lastError = .connectionFailed("HTTP \(httpResponse.statusCode): \(bodyText.prefix(200))")
                    continue // retry on server errors

                default:
                    let bodyText = String(data: data, encoding: .utf8) ?? ""
                    throw MCPError.connectionFailed("HTTP \(httpResponse.statusCode): \(bodyText.prefix(200))")
                }
            }

            // Success path — parse response

            if !expectResponse { return [:] }

            // Handle both plain JSON and SSE (text/event-stream) formats.
            // GitHub MCP may respond with SSE: "event: message\ndata: {...}\n\n"
            let responseData: Data
            if let contentType = (urlResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
               contentType.contains("text/event-stream"),
               let bodyText = String(data: data, encoding: .utf8) {
                responseData = extractJSONFromSSE(bodyText)
            } else {
                responseData = data
            }

            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                throw MCPError.invalidResponse
            }

            // Check for JSON-RPC error
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown error"
                let code = error["code"] as? Int
                if code == -32600 || code == -32601 {
                    throw MCPError.toolNotFound(message)
                }
                throw MCPError.toolCallFailed(message)
            }

            return json
        }

        // All retries exhausted
        throw lastError
    }

    /// Extracts JSON-RPC response from SSE (Server-Sent Events) body.
    /// SSE format: "event: message\ndata: {json}\n\n"
    /// For multi-event streams, returns the last JSON-RPC response (with matching id).
    private func extractJSONFromSSE(_ sseText: String) -> Data {
        var lastData: Data?

        for line in sseText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data:") {
                let jsonStr = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["jsonrpc"] != nil {
                    lastData = data
                }
            }
        }

        return lastData ?? sseText.data(using: .utf8) ?? Data()
    }
}

// MARK: - Types

/// Describes an MCP tool discovered via `tools/list`.
struct MCPToolInfo {
    let name: String
    let description: String?
}

/// Result from an MCP `tools/call` invocation.
struct MCPToolResult {
    let text: String
    let isError: Bool
    let raw: [String: Any]
}
