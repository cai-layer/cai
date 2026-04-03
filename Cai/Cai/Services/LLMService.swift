import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Chat Message

/// A single message in the chat conversation.
/// Public so ActionListWindow can build and manage conversation history for follow-ups.
struct ChatMessage: Encodable {
    let role: String   // "system", "user", "assistant"
    let content: String
}

// MARK: - LLM Service

/// Communicates with a local OpenAI-compatible API (LM Studio, Ollama, etc.)
/// All methods are isolated to the actor to ensure thread safety.
actor LLMService {

    static let shared = LLMService()

    /// Cached model name from the last successful status check.
    /// Used in generate() requests — some providers (LM Studio) require it.
    private var cachedModelName: String?

    /// Applies the API key as a Bearer token if one is configured.
    private func applyAuth(to request: inout URLRequest) async {
        let key = await MainActor.run { CaiSettings.shared.apiKey }
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - Status

    struct Status {
        let available: Bool
        let modelName: String?
        let error: String?
    }

    /// Checks if the LLM server is reachable and has a loaded model.
    func checkStatus() async -> Status {
        let provider = await MainActor.run { CaiSettings.shared.modelProvider }

        // Built-in MLX — check if model is loaded in-process
        if provider == .builtIn {
            let loaded = await MLXInference.shared.isLoaded
            return Status(
                available: loaded,
                modelName: loaded ? "MLX Built-in" : nil,
                error: loaded ? nil : "No model loaded"
            )
        }

        // Apple Intelligence — check on-device model availability
        if provider == .apple {
            return checkAppleFMStatus()
        }

        let baseURL = await MainActor.run { CaiSettings.shared.modelURL }
        guard !baseURL.isEmpty,
              baseURL.hasPrefix("http"),
              let url = URL(string: "\(baseURL)/v1/models") else {
            return Status(available: false, modelName: nil, error: "Invalid model URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        await applyAuth(to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return Status(available: false, modelName: nil, error: "Server returned non-200")
            }
            // Extract first model name — required by some providers
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]],
               let first = models.first,
               let modelId = first["id"] as? String {
                cachedModelName = modelId
                return Status(available: true, modelName: modelId, error: nil)
            }
            // Server is up but no models loaded
            cachedModelName = nil
            return Status(available: false, modelName: nil, error: "No models loaded")
        } catch {
            return Status(available: false, modelName: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Available Models

    /// Fetches the list of all available model names from the server.
    func availableModels() async -> [String] {
        let provider = await MainActor.run { CaiSettings.shared.modelProvider }
        if provider == .builtIn {
            let loaded = await MLXInference.shared.isLoaded
            return loaded ? ["MLX Built-in"] : []
        }
        if provider == .apple {
            return ["Apple Intelligence"]
        }

        let baseURL = await MainActor.run { CaiSettings.shared.modelURL }
        guard !baseURL.isEmpty,
              baseURL.hasPrefix("http"),
              let url = URL(string: "\(baseURL)/v1/models") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        await applyAuth(to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]] {
                return models.compactMap { $0["id"] as? String }
            }
        } catch {}
        return []
    }

    // MARK: - Prompt Templates

    /// Returns the (system, user) prompt pair for a given LLM action.
    /// Extracted so callers can build conversation history for follow-ups
    /// without duplicating prompt strings.
    nonisolated static func prompts(
        for action: LLMAction,
        text: String,
        appContext: String?
    ) -> (system: String, user: String) {
        let context = appContext.map { " (from \($0))" } ?? ""
        switch action {
        case .summarize:
            return (
                system: "Output only the summary.\(context) Use bullet points. No preamble, no introductions. For math, use Unicode symbols.",
                user: "Summarize this in 2-3 bullet points. Each bullet should be one sentence. Capture the key points only.\n\n\(text)"
            )
        case .translate(let lang):
            return (
                system: "You are a translator.\(context) Output only the translation. Preserve the original tone, formatting, and line breaks.",
                user: "Translate to \(lang):\n\n\(text)"
            )
        case .define:
            return (
                system: "You are a dictionary. Be concise. Output only the definition in the exact format requested.",
                user: "Define \"\(text)\". Use this format:\n**\(text)** (part of speech) \u{2014} definition.\nExample: \"sentence using the word.\""
            )
        case .explain:
            return (
                system: "Explain clearly in plain language.\(context) Under 100 words. Start directly \u{2014} no preamble. For math, use Unicode symbols.",
                user: "Explain this:\n\n\(text)"
            )
        case .reply:
            return (
                system: "Write a reply to the message below.\(context) Match the tone, language and formality of the original. Be concise. Output only the reply \u{2014} no preamble. Do not use any markdown formatting (no **, no *, no #, no `).",
                user: text
            )
        case .proofread:
            return (
                system: "You are a proofreader.\(context) Fix grammar, spelling, and punctuation errors. Keep the original meaning, tone, and style. Output only the corrected text \u{2014} no explanations, no comments. Do not use any markdown formatting (no **, no *, no #, no `).",
                user: "Proofread and return only the corrected version:\n\n\(text)"
            )
        case .custom(let instruction):
            return (
                system: "Output ONLY the processed text.\(context) No comments, no introductions, no \"Here is...\" \u{2014} the result is copied directly to clipboard. For math, use Unicode symbols.",
                user: "\(instruction)\n\n\(text)"
            )
        }
    }

    // MARK: - Generation

    /// Sends a pre-built messages array to the chat completions endpoint.
    /// Used by follow-up conversations where the caller manages message history.
    func generateWithMessages(_ messages: [ChatMessage]) async throws -> String {
        let provider = await MainActor.run { CaiSettings.shared.modelProvider }

        // Built-in MLX — route to in-process MLX inference
        if provider == .builtIn {
            return try await generateWithMLX(messages)
        }

        // Apple Intelligence — route to on-device FoundationModels
        if provider == .apple {
            return try await generateWithAppleFM(messages)
        }

        let baseURL = await MainActor.run { CaiSettings.shared.modelURL }
        guard !baseURL.isEmpty,
              baseURL.hasPrefix("http"),
              let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw LLMError.invalidURL
        }

        // Use user-specified model name if set, otherwise auto-detect
        let userModel = await MainActor.run { CaiSettings.shared.modelName }
        let modelToUse: String
        if !userModel.isEmpty {
            modelToUse = userModel
        } else {
            if cachedModelName == nil {
                _ = await checkStatus()
            }
            modelToUse = cachedModelName ?? ""
        }

        let body = ChatRequest(
            model: modelToUse,
            messages: messages,
            temperature: 0.3,
            max_tokens: 1024
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(body)
        await applyAuth(to: &request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            CrashReportingService.shared.addBreadcrumb(category: "llm", message: "LLM request failed: \(urlError.localizedDescription)", level: .error)
            switch urlError.code {
            case .timedOut:
                throw LLMError.timeout
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost:
                throw LLMError.connectionFailed
            default:
                throw LLMError.connectionFailed
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.serverError(http.statusCode, body)
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content else {
            throw LLMError.emptyResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends a chat completion request and returns the assistant's response text.
    /// Thin wrapper that builds messages with "About You" context, then delegates
    /// to generateWithMessages().
    func generate(systemPrompt: String? = nil, userPrompt: String) async throws -> String {
        let aboutYou = await MainActor.run { CaiSettings.shared.aboutYou }

        // Build system prompt, prepending "About You" context if set
        var finalSystemPrompt = systemPrompt
        if !aboutYou.isEmpty {
            let userContext = "About the user: \(aboutYou)"
            if let existing = finalSystemPrompt {
                finalSystemPrompt = "\(userContext)\n\n\(existing)"
            } else {
                finalSystemPrompt = userContext
            }
        }

        var messages: [ChatMessage] = []
        if let system = finalSystemPrompt {
            messages.append(ChatMessage(role: "system", content: system))
        }
        messages.append(ChatMessage(role: "user", content: userPrompt))

        return try await generateWithMessages(messages)
    }

    // MARK: - Action Methods

    func summarize(_ text: String, appContext: String? = nil) async throws -> String {
        let p = Self.prompts(for: .summarize, text: text, appContext: appContext)
        return try await generate(systemPrompt: p.system, userPrompt: p.user)
    }

    func translate(_ text: String, to language: String, appContext: String? = nil) async throws -> String {
        let p = Self.prompts(for: .translate(language), text: text, appContext: appContext)
        return try await generate(systemPrompt: p.system, userPrompt: p.user)
    }

    func define(_ word: String) async throws -> String {
        let p = Self.prompts(for: .define, text: word, appContext: nil)
        return try await generate(systemPrompt: p.system, userPrompt: p.user)
    }

    func explain(_ text: String, appContext: String? = nil) async throws -> String {
        let p = Self.prompts(for: .explain, text: text, appContext: appContext)
        return try await generate(systemPrompt: p.system, userPrompt: p.user)
    }

    func reply(_ text: String, appContext: String? = nil) async throws -> String {
        let p = Self.prompts(for: .reply, text: text, appContext: appContext)
        return try await generate(systemPrompt: p.system, userPrompt: p.user)
    }

    func proofread(_ text: String, appContext: String? = nil) async throws -> String {
        let p = Self.prompts(for: .proofread, text: text, appContext: appContext)
        return try await generate(systemPrompt: p.system, userPrompt: p.user)
    }

    func customAction(_ text: String, instruction: String, appContext: String? = nil) async throws -> String {
        let p = Self.prompts(for: .custom(instruction), text: text, appContext: appContext)
        return try await generate(systemPrompt: p.system, userPrompt: p.user)
    }
    // MARK: - Built-in MLX Inference

    /// Generates a response using the built-in MLX model (in-process, no subprocess).
    private func generateWithMLX(_ messages: [ChatMessage]) async throws -> String {
        guard await MLXInference.shared.isLoaded else {
            throw LLMError.connectionFailed
        }

        let tuples = messages.map { (role: $0.role, content: $0.content) }
        return try await MLXInference.shared.generate(messages: tuples)
    }

    /// Returns a streaming response from the built-in MLX model.
    /// Used by ResultView for progressive token display.
    func generateStreamingWithMessages(_ messages: [ChatMessage]) async throws -> AsyncThrowingStream<String, Error> {
        let provider = await MainActor.run { CaiSettings.shared.modelProvider }
        guard provider == .builtIn else {
            // Non-MLX providers: wrap full response as a single-element stream
            let fullResponse = try await generateWithMessages(messages)
            return AsyncThrowingStream { continuation in
                continuation.yield(fullResponse)
                continuation.finish()
            }
        }

        guard await MLXInference.shared.isLoaded else {
            throw LLMError.connectionFailed
        }

        let tuples = messages.map { (role: $0.role, content: $0.content) }
        return try await MLXInference.shared.generateStream(messages: tuples)
    }

    // MARK: - Apple Intelligence (FoundationModels)

    /// Checks Apple Intelligence on-device model availability.
    private func checkAppleFMStatus() -> Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let availability = SystemLanguageModel.default.availability
            switch availability {
            case .available:
                return Status(available: true, modelName: "Apple Intelligence", error: nil)
            default:
                return Status(available: false, modelName: nil, error: "Apple Intelligence not available")
            }
        }
        #endif
        return Status(available: false, modelName: nil, error: "Requires macOS 26+")
    }

    /// Generates a response using Apple's on-device Foundation Models.
    /// Creates a fresh session per request. For follow-ups, replays the conversation
    /// so the session builds up context via its built-in transcript.
    private func generateWithAppleFM(_ messages: [ChatMessage]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let model = SystemLanguageModel.default
            guard model.availability == .available else {
                throw LLMError.appleIntelligenceUnavailable
            }

            // Extract system prompt (instructions) from messages
            let systemPrompt = messages.first(where: { $0.role == "system" })?.content ?? ""
            let session = LanguageModelSession(instructions: systemPrompt)

            // Collect user messages in order
            let userMessages = messages.filter { $0.role == "user" }
            guard !userMessages.isEmpty else {
                throw LLMError.emptyResponse
            }

            // For follow-ups, replay earlier user messages to build session context.
            // Each respond() call adds to the session transcript automatically.
            if userMessages.count > 1 {
                for userMsg in userMessages.dropLast() {
                    _ = try await session.respond(to: userMsg.content)
                }
            }

            // Send the final (or only) user message
            let response = try await session.respond(to: userMessages.last!.content)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw LLMError.appleIntelligenceUnavailable
    }
}

// MARK: - API Types

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let max_tokens: Int
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message

        struct Message: Decodable {
            let content: String
        }
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(Int, String)
    case emptyResponse
    case connectionFailed
    case timeout
    case appleIntelligenceUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid model URL. Check Settings \u{2192} Model Provider."
        case .invalidResponse:
            return "Invalid response from server."
        case .serverError(let code, let body):
            return "Server error (\(code)): \(body)"
        case .emptyResponse:
            return "Empty response from model."
        case .connectionFailed:
            return "Could not connect to LLM server. Is it running?"
        case .timeout:
            return "Request timed out. Is your LLM server running?"
        case .appleIntelligenceUnavailable:
            return "Apple Intelligence requires macOS 26+ with Apple Intelligence enabled."
        }
    }
}
