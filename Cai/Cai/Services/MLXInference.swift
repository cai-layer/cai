import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - MLX Inference Service

/// In-process LLM inference via MLX-Swift. Replaces the llama-server subprocess.
/// Loads MLX-format models from disk or HuggingFace and runs inference natively on Apple Silicon.
actor MLXInference {

    static let shared = MLXInference()

    // MARK: - Directories (nonisolated for synchronous access from CaiSettings etc.)

    nonisolated static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cai")
    }

    // MARK: - State

    private var modelContainer: ModelContainer?
    private var memoryConfigured = false

    // Session reuse: persist ChatSession across follow-up calls to avoid
    // replaying the full conversation history on each turn.
    private var currentSession: ChatSession?
    private var currentSystemPrompt: String?
    private var currentSessionUserTurnCount: Int = 0

    /// Set while a generation (streaming or non-streaming) is in flight.
    /// Concurrent generate/stream calls would race on the underlying ModelContainer
    /// — `ChatSession` is not safe for parallel token generation on the same model.
    /// We reject overlapping calls with a clear error rather than corrupting state.
    private var isGenerating: Bool = false

    /// Whether a model is currently loaded and ready for inference.
    var isLoaded: Bool { modelContainer != nil }

    // MARK: - Load Model

    /// Configures MLX memory limits. Runs once — subsequent calls are no-ops.
    private func configureMemory() {
        guard !memoryConfigured else { return }
        memoryConfigured = true
        // 256MB buffer pool — balances reallocation churn vs memory footprint.
        // 20MB (iOS recommendation) causes excessive churn on macOS.
        // No memoryLimit — macOS unified memory pressure handles the rest,
        // and setting it too low can hang the process (no relaxed mode in mlx-swift).
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
    }

    /// Loads an MLX model from a local directory (already downloaded).
    func loadModel(from directory: URL) async throws {
        if modelContainer != nil { unload() }
        configureMemory()
        print("🧠 MLX loading model from: \(directory.path)")
        let container = try await loadModelContainer(directory: directory)
        self.modelContainer = container
        print("🧠 MLX model loaded successfully")
    }

    /// Downloads and loads a model from HuggingFace by ID (e.g., "mlx-community/Ministral-3-3B-Instruct-2512-4bit").
    func loadModel(
        id: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        if modelContainer != nil { unload() }
        configureMemory()
        print("🧠 MLX loading model: \(id)")
        let container = try await loadModelContainer(
            id: id,
            progressHandler: progressHandler
        )
        self.modelContainer = container
        print("🧠 MLX model ready: \(id)")
    }

    // MARK: - Session Resolution

    /// Resolves whether to reuse the existing ChatSession (follow-up) or create a new one.
    /// ChatSession maintains internal KV cache across respond() calls, so reusing it
    /// avoids replaying the full conversation history on each follow-up turn.
    private func resolveSession(
        messages: [(role: String, content: String)],
        config: GenerationConfig
    ) async throws -> (session: ChatSession, lastUserMessage: String) {
        guard let container = modelContainer else {
            throw MLXInferenceError.modelNotLoaded
        }

        let systemPrompt = messages.first(where: { $0.role == "system" })?.content
        let userMessages = messages.filter { $0.role == "user" }
        guard let lastUserMessage = userMessages.last?.content else {
            throw MLXInferenceError.modelNotLoaded
        }

        // Follow-up detection: same system prompt + exactly one new user message
        if let session = currentSession,
           currentSystemPrompt == systemPrompt,
           userMessages.count == currentSessionUserTurnCount + 1 {
            return (session, lastUserMessage)
        }

        // New conversation — create fresh session with tuned parameters
        let params = GenerateParameters(
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            topP: config.topP,
            repetitionPenalty: config.repetitionPenalty
        )
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: params
        )

        currentSession = session
        currentSystemPrompt = systemPrompt
        currentSessionUserTurnCount = 0

        // Edge case: session was invalidated mid-conversation (model switch, etc.)
        // and caller is retrying with the full history. Replay earlier turns.
        if userMessages.count > 1 {
            for userMsg in userMessages.dropLast() {
                _ = try await session.respond(to: userMsg.content)
                currentSessionUserTurnCount += 1
            }
        }

        return (session, lastUserMessage)
    }

    // MARK: - Generate

    /// Generates a complete response (non-streaming).
    func generate(
        messages: [(role: String, content: String)],
        config: GenerationConfig = .default
    ) async throws -> String {
        guard !isGenerating else { throw MLXInferenceError.busy }
        isGenerating = true
        defer { isGenerating = false }

        let (session, lastUserMessage) = try await resolveSession(
            messages: messages, config: config
        )
        let result = try await session.respond(to: lastUserMessage)
        currentSessionUserTurnCount += 1
        return result
    }

    /// Generates a streaming response. Returns an AsyncThrowingStream of string chunks.
    func generateStream(
        messages: [(role: String, content: String)],
        config: GenerationConfig = .default
    ) throws -> AsyncThrowingStream<String, Error> {
        guard modelContainer != nil else {
            throw MLXInferenceError.modelNotLoaded
        }
        guard !isGenerating else { throw MLXInferenceError.busy }
        isGenerating = true

        let capturedMessages = messages
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (session, lastUserMessage) = try await self.resolveSession(
                        messages: capturedMessages, config: config
                    )
                    // MLX ChatSession.streamResponse yields DELTAS (just the new tokens).
                    // We accumulate and yield CUMULATIVE strings so ResultView can consume
                    // them uniformly — matching Apple FoundationModels' `partial.content` format.
                    let stream = session.streamResponse(to: lastUserMessage)
                    var accumulated = ""
                    for try await delta in stream {
                        accumulated += delta
                        continuation.yield(accumulated)
                    }
                    // Only count the turn after stream completes successfully.
                    // If cancelled mid-stream, the mismatch triggers a fresh session next time.
                    self.currentSessionUserTurnCount += 1
                    self.isGenerating = false
                    continuation.finish()
                } catch {
                    self.isGenerating = false
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Unloads the model and frees memory.
    func unload() {
        modelContainer = nil
        currentSession = nil
        currentSystemPrompt = nil
        currentSessionUserTurnCount = 0
        // Clear busy flag so a stuck stream (e.g., from model switch) doesn't
        // permanently lock out new generations.
        isGenerating = false
        print("🧠 MLX model unloaded")
    }
}

// MARK: - Errors

enum MLXInferenceError: LocalizedError {
    case modelNotLoaded
    case busy

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No AI model is loaded. Please download a model in Settings."
        case .busy:
            return "Another AI action is in progress. Please wait for it to finish."
        }
    }
}
