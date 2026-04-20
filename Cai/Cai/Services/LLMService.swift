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

// MARK: - Generation Config

/// Per-action generation parameters. Different actions benefit from different
/// sampling settings — translations want deterministic output, creative prompts
/// want higher temperature, etc.
///
/// Only MLX uses all parameters. Apple FoundationModels handles sampling
/// internally and ignores these values — that's fine, the config is passed
/// uniformly and each provider uses what it can.
struct GenerationConfig {
    var temperature: Float
    var topP: Float
    var maxTokens: Int
    /// Penalty factor for repeating tokens (MLX only). nil = model default.
    /// Intentionally unset — testing with Ministral 3B showed 1.1 caused token
    /// corruption in some outputs. Safer to rely on model defaults.
    var repetitionPenalty: Float?

    static let `default` = GenerationConfig(
        temperature: 0.3, topP: 0.9, maxTokens: 1024, repetitionPenalty: nil
    )

    /// Returns tuned parameters for a given LLM action.
    /// Rationale per action:
    /// - Translate/Proofread: 0.0 — deterministic, same input → same output
    /// - Define: 0.1, focused budget — short factual
    /// - Summarize: 0.3 — factual with room for phrasing variation
    /// - Explain: 0.3 — some phrasing variation
    /// - Reply: 0.5 — natural tone variation
    /// - Custom: 0.6 — user intent varies, allow creativity
    ///
    /// maxTokens are generous to avoid mid-sentence truncation. Small models
    /// rarely approach the limit; the cost of being generous is negligible.
    static func forAction(_ action: LLMAction) -> GenerationConfig {
        switch action {
        case .translate:
            return GenerationConfig(temperature: 0.0, topP: 0.9, maxTokens: 800, repetitionPenalty: nil)
        case .proofread:
            return GenerationConfig(temperature: 0.0, topP: 0.9, maxTokens: 800, repetitionPenalty: nil)
        case .define:
            return GenerationConfig(temperature: 0.1, topP: 0.9, maxTokens: 300, repetitionPenalty: nil)
        case .summarize:
            return GenerationConfig(temperature: 0.3, topP: 0.9, maxTokens: 600, repetitionPenalty: nil)
        case .explain:
            return GenerationConfig(temperature: 0.3, topP: 0.9, maxTokens: 600, repetitionPenalty: nil)
        case .reply:
            return GenerationConfig(temperature: 0.5, topP: 0.9, maxTokens: 500, repetitionPenalty: nil)
        case .custom:
            return GenerationConfig(temperature: 0.6, topP: 0.95, maxTokens: 1024, repetitionPenalty: nil)
        }
    }
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
    /// Picks the right key per provider so OpenRouter's key doesn't clobber
    /// a local LM Studio / Ollama setup (and vice versa).
    private func applyAuth(to request: inout URLRequest) async {
        let provider = await MainActor.run { CaiSettings.shared.modelProvider }
        let key: String
        switch provider {
        case .openrouter:
            key = await MainActor.run { CaiSettings.shared.openRouterApiKey }
            // OpenRouter uses these for traffic attribution on their model leaderboards.
            // Harmless to send, helps us show up as a known client.
            request.setValue("https://getcai.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Cai", forHTTPHeaderField: "X-Title")
        default:
            key = await MainActor.run { CaiSettings.shared.apiKey }
        }
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

        // Anthropic, check API key is configured. No validation call, Anthropic's
        // API has quirks with lightweight probe requests (intermittent temperature/top_p
        // rejection on alias model IDs). Real errors surface on first action instead.
        if provider == .anthropic {
            let key = await MainActor.run { CaiSettings.shared.anthropicApiKey }
            if key.isEmpty {
                return Status(available: false, modelName: nil, error: "No API key")
            }
            let model = await MainActor.run { CaiSettings.shared.anthropicModelName }
            return Status(available: true, modelName: model, error: nil)
        }

        // OpenRouter — probe /api/v1/key (auth-required) so the status indicator
        // reflects whether the key actually works, not just whether the field
        // is non-empty. /v1/models is public on OpenRouter so it would give a
        // false-positive green on an invalid key.
        if provider == .openrouter {
            let key = await MainActor.run { CaiSettings.shared.openRouterApiKey }
            if key.isEmpty {
                return Status(available: false, modelName: nil, error: "No API key")
            }
            guard let probeURL = URL(string: "https://openrouter.ai/api/v1/key") else {
                return Status(available: false, modelName: nil, error: "Invalid probe URL")
            }
            var probe = URLRequest(url: probeURL)
            probe.timeoutInterval = 5
            probe.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            do {
                let (_, response) = try await URLSession.shared.data(for: probe)
                guard let http = response as? HTTPURLResponse else {
                    return Status(available: false, modelName: nil, error: "Invalid response")
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    return Status(available: false, modelName: nil, error: "Invalid API key")
                }
                if http.statusCode != 200 {
                    return Status(available: false, modelName: nil, error: "OpenRouter returned \(http.statusCode)")
                }
            } catch {
                return Status(available: false, modelName: nil, error: "Cannot reach OpenRouter")
            }
            let model = await MainActor.run { CaiSettings.shared.openRouterModelName }
            let resolved = model.isEmpty ? CaiSettings.defaultOpenRouterModel : model
            return Status(available: true, modelName: resolved, error: nil)
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
        if provider == .anthropic {
            let model = await MainActor.run { CaiSettings.shared.anthropicModelName }
            return [model]
        }
        // OpenRouter: only query if the user has entered a key. Their /v1/models
        // endpoint is actually open to unauth'd callers, but we want the list to
        // act as a key validity signal, so no key means no list.
        if provider == .openrouter {
            let key = await MainActor.run { CaiSettings.shared.openRouterApiKey }
            if key.isEmpty { return [] }
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
                let ids = models.compactMap { $0["id"] as? String }
                // OpenRouter returns models in popularity / recency order, which
                // isn't scannable when there are 400+ of them. Sort for that case.
                if provider == .openrouter {
                    return ids.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                }
                return ids
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
                system: "Output only the summary.\(context) Use short lines starting with \"\u{2022} \" (Unicode bullet + space) for each point. No preamble, no introductions, no markdown syntax (no **, no __, no #, no -, no [ ]). For math, use Unicode symbols.",
                user: "Summarize this in 2-3 bullet points. Each bullet should be one sentence. Capture the key points only.\n\n\(text)"
            )
        case .translate(let lang):
            return (
                system: "You are a translator.\(context) Output only the translation. Preserve the original tone, formatting, and line breaks. Do not add markdown syntax that wasn't in the original.",
                user: "Translate to \(lang):\n\n\(text)"
            )
        case .define:
            return (
                system: "You are a dictionary. Be concise. Output only the definition in the exact format requested.",
                user: "Define \"\(text)\". Use this format:\n**\(text)** (part of speech) \u{2014} definition.\nExample: \"sentence using the word.\""
            )
        case .explain:
            return (
                system: "Explain clearly in plain language.\(context) Under 100 words. Start directly \u{2014} no preamble. Plain text only \u{2014} no markdown syntax (no **, no __, no #, no -, no [ ]). For math, use Unicode symbols.",
                user: "Explain this:\n\n\(text)"
            )
        case .reply:
            return (
                system: "Write a reply to the message below.\(context) Match the tone, language and formality of the original. Be concise. Output only the reply \u{2014} no preamble. Do not use any markdown formatting (no **, no *, no #, no `).",
                user: text
            )
        case .proofread:
            return (
                system: "You are a proofreader.\(context) Fix ALL grammar errors including pronoun case (he/I not him/me), capitalization, and agreement. Never preserve errors. Keep the original meaning and tone. Output only the corrected text \u{2014} no explanations, no markdown.",
                user: "Proofread and return only the corrected version:\n\n\(text)"
            )
        case .custom(let instruction):
            return (
                system: "Output ONLY the processed text.\(context) No comments, no introductions, no \"Here is...\" \u{2014} the result is copied directly to clipboard. Plain text only \u{2014} no markdown syntax (no **, no __, no #, no -, no [ ]). For math, use Unicode symbols.",
                user: "\(instruction)\n\nInput:\n\(text)"
            )
        }
    }

    // MARK: - Message Builder

    /// Builds the initial `[ChatMessage]` array for an LLM action, layering in
    /// optional global "About You" context and an optional per-app Context Snippet.
    ///
    /// This is a `nonisolated static` pure function — no actor state, no singleton
    /// access — so it's fully unit-testable in isolation. Callers resolve the
    /// inputs (`aboutYou` from CaiSettings, `snippet` from ContextSnippetsManager)
    /// and pass them in; this function just formats the messages array.
    ///
    /// **Injection order (outer → inner in the final system prompt):**
    ///
    /// ```text
    ///   About the user: {aboutYou}          ← outermost (global)
    ///
    ///   [App context: {snippet.appName}]    ← middle (per-app)
    ///   {snippet.context}
    ///
    ///   {systemPrompt}                       ← innermost (action)
    /// ```
    ///
    /// The `[App context: ...]` label is important for small 3B models — they
    /// respond well to named sections as delimiters.
    ///
    /// - Parameters:
    ///   - systemPrompt: Action-specific system prompt from `prompts(for:)`
    ///   - userPrompt: Action-specific user prompt from `prompts(for:)`
    ///   - aboutYou: Global user context (empty string → not injected)
    ///   - snippet: Per-app context snippet (nil → not injected)
    /// - Returns: `[system message, user message]` ready for LLM dispatch
    nonisolated static func buildMessages(
        systemPrompt: String,
        userPrompt: String,
        aboutYou: String,
        snippet: ContextSnippet?
    ) -> [ChatMessage] {
        var finalSystem = systemPrompt

        // Build inside-out: snippet wraps the system prompt first…
        if let snippet {
            let header = "[App context: \(snippet.appName)]"
            finalSystem = "\(header)\n\(snippet.context)\n\n\(finalSystem)"
        }

        // …then "About You" wraps everything.
        if !aboutYou.isEmpty {
            finalSystem = "About the user: \(aboutYou)\n\n\(finalSystem)"
        }

        return [
            ChatMessage(role: "system", content: finalSystem),
            ChatMessage(role: "user", content: userPrompt)
        ]
    }

    // MARK: - Follow-up System Prompt

    /// Builds the system prompt used for follow-up turns (Tab → ask question after a result).
    ///
    /// **Why this exists:** the turn-1 system prompt is action-specific (e.g. *"Output only
    /// the summary…"*). When the user asks an unrelated follow-up like *"What's a cell?"*
    /// after a Summarize, that contradictory framing causes Apple Intelligence to refuse
    /// (and pollutes context for stricter MLX models). On follow-up we swap to a
    /// conversational system prompt — but we MUST preserve the same outer wrapping
    /// (`About the user: …` and `[App context: …]`) that `buildMessages` applies for
    /// turn 1, otherwise users silently lose their personalization on every follow-up.
    ///
    /// Wrapping order matches `buildMessages` exactly (outer → inner):
    ///
    /// ```text
    ///   About the user: {aboutYou}          ← outermost (only if non-empty)
    ///
    ///   [App context: {snippet.appName}]    ← middle (only if snippet != nil)
    ///   {snippet.context}
    ///
    ///   {conversational core}                ← innermost
    /// ```
    ///
    /// `nonisolated static` so it's pure and unit-testable in isolation.
    nonisolated static func buildFollowUpSystemPrompt(
        aboutYou: String,
        snippet: ContextSnippet?
    ) -> String {
        let core = """
            You are a helpful assistant continuing a conversation. Answer ONLY the user's \
            latest follow-up question \u{2014} do not repeat or summarize previous answers. \
            Keep your response focused on what was just asked. Plain text only \
            \u{2014} no markdown syntax (no **, no __, no #, no -, no [ ]). For math, use Unicode symbols.
            """

        var prompt = core

        if let snippet {
            let header = "[App context: \(snippet.appName)]"
            prompt = "\(header)\n\(snippet.context)\n\n\(prompt)"
        }

        if !aboutYou.isEmpty {
            prompt = "About the user: \(aboutYou)\n\n\(prompt)"
        }

        return prompt
    }

    // MARK: - Input Truncation

    /// Maximum characters per message sent to the LLM. ~12.5K tokens for English text,
    /// well under Ministral 3B's 32K context window. Prevents memory pressure / OOM
    /// on 8GB Macs and cryptic context-window errors when users paste huge documents.
    /// Apple Intelligence (4K token limit) will still hit its own ceiling for content
    /// over ~12K chars and surface a contentFiltered/length error from its side.
    private static let maxMessageChars: Int = 50_000

    /// Truncates each message's content to `maxMessageChars`. Logs when truncation occurs.
    /// Applied at this single chokepoint so all providers (MLX, Apple FM, external HTTP)
    /// get the same behavior automatically.
    private static func truncateMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        return messages.map { msg in
            guard msg.content.count > maxMessageChars else { return msg }
            print("✂️ Truncating LLM \(msg.role) message: \(msg.content.count) → \(maxMessageChars) chars")
            let truncated = String(msg.content.prefix(maxMessageChars))
            return ChatMessage(role: msg.role, content: truncated)
        }
    }

    // MARK: - Generation

    /// Sends a pre-built messages array to the chat completions endpoint.
    /// Used by follow-up conversations where the caller manages message history.
    /// `config` lets callers tune generation parameters per action (see `GenerationConfig.forAction`).
    func generateWithMessages(
        _ messages: [ChatMessage],
        config: GenerationConfig = .default
    ) async throws -> String {
        let messages = Self.truncateMessages(messages)
        let provider = await MainActor.run { CaiSettings.shared.modelProvider }

        // Built-in MLX — route to in-process MLX inference
        if provider == .builtIn {
            return try await generateWithMLX(messages, config: config)
        }

        // Apple Intelligence — route to on-device FoundationModels
        if provider == .apple {
            return try await generateWithAppleFM(messages)
        }

        // Anthropic — route to Claude API (/v1/messages)
        if provider == .anthropic {
            return try await generateWithAnthropic(messages, config: config)
        }

        let baseURL = await MainActor.run { CaiSettings.shared.modelURL }
        guard !baseURL.isEmpty,
              baseURL.hasPrefix("http"),
              let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw LLMError.invalidURL
        }

        // Use user-specified model name if set, otherwise auto-detect.
        // OpenRouter has its own dedicated slug field since auto-detect against
        // their /v1/models (hundreds of entries) would pick a random first model.
        let modelToUse: String
        if provider == .openrouter {
            let slug = await MainActor.run { CaiSettings.shared.openRouterModelName }
            modelToUse = slug.isEmpty ? CaiSettings.defaultOpenRouterModel : slug
        } else {
            let userModel = await MainActor.run { CaiSettings.shared.modelName }
            if !userModel.isEmpty {
                modelToUse = userModel
            } else {
                if cachedModelName == nil {
                    _ = await checkStatus()
                }
                modelToUse = cachedModelName ?? ""
            }
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
            // Auth failures are the #1 user-facing confusion for cloud providers.
            // Surface a concrete action instead of the raw server body.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw LLMError.serverError(http.statusCode, "Authentication failed — check your API key in Settings → Model Provider.")
            }
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
    private func generateWithMLX(_ messages: [ChatMessage], config: GenerationConfig) async throws -> String {
        guard await MLXInference.shared.isLoaded else {
            throw LLMError.builtInModelNotLoaded
        }

        let tuples = messages.map { (role: $0.role, content: $0.content) }
        return try await MLXInference.shared.generate(messages: tuples, config: config)
    }

    /// Returns a streaming response from the built-in MLX model.
    /// Used by ResultView for progressive token display.
    func generateStreamingWithMessages(
        _ messages: [ChatMessage],
        config: GenerationConfig = .default
    ) async throws -> AsyncThrowingStream<String, Error> {
        let messages = Self.truncateMessages(messages)
        let provider = await MainActor.run { CaiSettings.shared.modelProvider }

        // Built-in MLX — native streaming
        if provider == .builtIn {
            guard await MLXInference.shared.isLoaded else {
                throw LLMError.builtInModelNotLoaded
            }
            let tuples = messages.map { (role: $0.role, content: $0.content) }
            return try await MLXInference.shared.generateStream(messages: tuples, config: config)
        }

        // Apple Intelligence — streaming via FoundationModels
        #if canImport(FoundationModels)
        if provider == .apple, #available(macOS 26, *) {
            return try await streamWithAppleFM(messages)
        }
        #endif

        // External providers (LM Studio, Ollama, custom): wrap full response as single-element stream
        let fullResponse = try await generateWithMessages(messages, config: config)
        return AsyncThrowingStream { continuation in
            continuation.yield(fullResponse)
            continuation.finish()
        }
    }

    // MARK: - Anthropic (Claude API)

    /// Sends messages to the Anthropic /v1/messages endpoint.
    /// Extracts the system message (already contains action prompt + Context Snippet + About You)
    /// and passes it as the top-level `system` param. Remaining user/assistant messages become
    /// the `messages` array. Follow-up conversations work automatically — the caller builds
    /// the full message history before calling generateWithMessages().
    private func generateWithAnthropic(
        _ messages: [ChatMessage],
        config: GenerationConfig
    ) async throws -> String {
        let key = await MainActor.run { CaiSettings.shared.anthropicApiKey }
        guard !key.isEmpty else {
            throw LLMError.serverError(401, "No API key configured. Add your Anthropic key in Settings.")
        }

        let model = await MainActor.run { CaiSettings.shared.anthropicModelName }

        // Extract system message (first message with role "system") → top-level param
        let systemMessage = messages.first(where: { $0.role == "system" })?.content

        // Filter to user/assistant messages only — Anthropic rejects system in messages array
        let conversationMessages = messages
            .filter { $0.role != "system" }
            .map { AnthropicMessage(role: $0.role, content: $0.content) }

        let body = AnthropicRequest(
            model: model,
            max_tokens: config.maxTokens,
            system: systemMessage,
            messages: conversationMessages
        )

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60  // Claude can be slower than local models
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            CrashReportingService.shared.addBreadcrumb(category: "llm", message: "Anthropic request failed: \(urlError.localizedDescription)", level: .error)
            switch urlError.code {
            case .timedOut:
                throw LLMError.timeout
            default:
                throw LLMError.connectionFailed
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard http.statusCode == 200 else {
            // Try to extract Anthropic's structured error message
            if let errorResponse = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
                throw LLMError.serverError(http.statusCode, errorResponse.error.message)
            }
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.serverError(http.statusCode, body)
        }

        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = anthropicResponse.content.first(where: { $0.type == "text" })?.text else {
            throw LLMError.emptyResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Builds a fresh Apple FM session seeded with the real prior conversation.
    ///
    /// We deliberately create a new session on every call (stateless) rather than
    /// reusing one across follow-ups. The previous session-reuse implementation
    /// carried bookkeeping state (system prompt, turn count, last-activity timestamp)
    /// and silently invalidated on any mismatch — which on follow-ups would create
    /// a fresh session with NO prior context (because the system prompt swap in
    /// `submitFollowUp` always changes the prompt). `LanguageModelSession(transcript:)`
    /// lets us seed the new session with the real prior turns directly, so the model
    /// sees actual `instructions` + `prompt` + `response` entries instead of losing
    /// context or seeing a hallucinated replay.
    ///
    /// API references verified against the macOS 26 SDK swiftinterface — every
    /// constructor used here is `public`. See `_docs/architecture/APPLE-FM-API.md`.
    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func buildAppleFMSession(
        from messages: [ChatMessage]
    ) throws -> (session: LanguageModelSession, latestUserMessage: String) {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw LLMError.appleIntelligenceUnavailable
        }

        let systemPrompt = messages.first(where: { $0.role == "system" })?.content ?? ""
        let turns = messages.filter { $0.role != "system" }
        guard let last = turns.last, last.role == "user" else {
            throw LLMError.emptyResponse
        }
        let priorTurns = turns.dropLast()

        // Turn-1 fast path: no history → use the simple instructions-only initializer.
        // Avoids the cost of building a Transcript when there's nothing to seed.
        if priorTurns.isEmpty {
            return (LanguageModelSession(instructions: systemPrompt), last.content)
        }

        // Follow-up path: build a Transcript from scratch with real prior entries.
        var entries: [Transcript.Entry] = []
        if !systemPrompt.isEmpty {
            let instructions = Transcript.Instructions(
                segments: [.text(.init(content: systemPrompt))],
                toolDefinitions: []
            )
            entries.append(.instructions(instructions))
        }
        for turn in priorTurns {
            let segment: Transcript.Segment = .text(.init(content: turn.content))
            switch turn.role {
            case "user":
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case "assistant":
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            default:
                // Unknown roles in conversation history aren't expected; skip rather than
                // pollute the transcript with miscoded turns.
                continue
            }
        }

        let transcript = Transcript(entries: entries)
        let session = LanguageModelSession(transcript: transcript)
        return (session, last.content)
    }

    /// Maps Apple FM errors to LLMError cases. Handles guardrail violations,
    /// context-window-exceeded, and other known cases.
    @available(macOS 26, *)
    private func mapAppleFMError(_ error: Error) -> Error {
        // String-based matching to be resilient across Apple's API evolution.
        // Note: this is fragile with localized errors — Apple may translate
        // descriptions on non-English Macs. Future improvement: type-check first.
        let description = String(describing: error).lowercased()
        if description.contains("guardrail")
            || description.contains("refusal")
            || (description.contains("content") && description.contains("polic")) {
            return LLMError.contentFiltered
        }
        return error
    }

    /// Detects Apple Intelligence refusal responses that come back as plain text
    /// rather than thrown errors. FoundationModels sometimes returns refusals like
    /// "Sorry, but I cannot fulfill that request." as a successful response body
    /// instead of throwing a guardrail error — we treat these as contentFiltered
    /// so the user sees a clear "Apple Intelligence declined" message instead of
    /// a cryptic one-liner in the result view.
    nonisolated static func isAppleFMRefusal(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Refusals are always short (< 200 chars) and start with a recognizable phrase.
        // Keep the list conservative to avoid false positives on legitimate responses.
        guard normalized.count < 200 else { return false }
        let refusalPrefixes = [
            "sorry, but i cannot",
            "sorry, but i can't",
            "i'm sorry, but i cannot",
            "i'm sorry, but i can't",
            "i cannot fulfill",
            "i can't fulfill",
            "i cannot help with",
            "i can't help with",
            "i'm unable to",
            "i am unable to",
        ]
        return refusalPrefixes.contains { normalized.hasPrefix($0) }
    }
    #endif

    /// Generates a response using Apple's on-device Foundation Models.
    /// Stateless: builds a fresh session seeded with the real prior conversation
    /// on every call. See `buildAppleFMSession` for the rationale.
    private func generateWithAppleFM(_ messages: [ChatMessage]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let (session, latestUserMessage) = try buildAppleFMSession(from: messages)
            do {
                let response = try await session.respond(to: latestUserMessage)
                let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                // Apple FM sometimes returns plain-text refusals instead of throwing.
                // Convert those to a proper error so the UI shows "Apple Intelligence declined…"
                if Self.isAppleFMRefusal(content) {
                    throw LLMError.contentFiltered
                }
                return content
            } catch {
                throw mapAppleFMError(error)
            }
        }
        #endif
        throw LLMError.appleIntelligenceUnavailable
    }

    /// Streams a response using Apple's on-device Foundation Models.
    /// Stateless: see `buildAppleFMSession`.
    private func streamWithAppleFM(_ messages: [ChatMessage]) async throws -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let (session, latestUserMessage) = try buildAppleFMSession(from: messages)
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        // Each `partial.content` is the CUMULATIVE text so far (the UI
                        // replaces `result = chunk` on each yield). We suppress early
                        // yields until we've seen ~30 chars so a plain-text refusal
                        // (e.g. "Sorry, but I cannot fulfill that request.") can be
                        // detected and converted into a contentFiltered error BEFORE
                        // any text is shown to the user.
                        let stream = session.streamResponse(to: latestUserMessage)
                        var lastContent = ""
                        var refusalChecked = false

                        for try await partial in stream {
                            lastContent = partial.content
                            if !refusalChecked && lastContent.count < 30 {
                                continue  // keep buffering — too short to classify
                            }
                            if !refusalChecked {
                                refusalChecked = true
                                if Self.isAppleFMRefusal(lastContent) {
                                    continuation.finish(throwing: LLMError.contentFiltered)
                                    return
                                }
                            }
                            continuation.yield(lastContent)
                        }

                        // Stream ended before we reached the 30-char threshold —
                        // classify and flush the final buffer.
                        if !refusalChecked {
                            if Self.isAppleFMRefusal(lastContent) {
                                continuation.finish(throwing: LLMError.contentFiltered)
                                return
                            }
                            if !lastContent.isEmpty {
                                continuation.yield(lastContent)
                            }
                        }

                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: self.mapAppleFMError(error))
                    }
                }
            }
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

// MARK: - Anthropic API Types

/// Internal (not private) so tests can verify request encoding and response decoding.
/// Custom encode(to:) omits `system` key when nil — Anthropic rejects `"system": null`.
struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [AnthropicMessage]

    private enum CodingKeys: String, CodingKey {
        case model, max_tokens, system, messages
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(max_tokens, forKey: .max_tokens)
        if let system { try container.encode(system, forKey: .system) }
        try container.encode(messages, forKey: .messages)
    }
}

struct AnthropicMessage: Codable, Equatable {
    let role: String      // "user" or "assistant" only — system is top-level
    let content: String
}

struct AnthropicResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}

private struct AnthropicErrorResponse: Decodable {
    let error: AnthropicErrorDetail

    struct AnthropicErrorDetail: Decodable {
        let type: String
        let message: String
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
    case builtInModelNotLoaded
    case appleIntelligenceUnavailable
    case contentFiltered

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
        case .builtInModelNotLoaded:
            return "No AI model is loaded. Please download a model in Settings."
        case .timeout:
            return "Request timed out. Is your LLM server running?"
        case .appleIntelligenceUnavailable:
            return "Apple Intelligence requires macOS 26+ with Apple Intelligence enabled."
        case .contentFiltered:
            return "Apple Intelligence declined this request due to content policy. Try the built-in AI or an external provider."
        }
    }
}
