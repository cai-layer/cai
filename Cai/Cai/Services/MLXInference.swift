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

    // MARK: - Session Inputs

    /// Converts Cai's `(role, content)` message tuples into MLX's session-input format.
    ///
    /// We deliberately create a fresh `ChatSession` on every generation call (stateless)
    /// rather than reusing one across follow-ups. The previous session-reuse implementation
    /// carried bookkeeping state (system prompt, turn count) and a replay loop that
    /// fabricated assistant responses to rebuild the KV cache on session invalidation —
    /// the replayed text didn't match what the user actually saw on screen, polluting
    /// context. `ChatSession(history:)` lets us seed a fresh session with the *real*
    /// prior turns directly (lazy prefill happens on the first `respond()` call).
    ///
    /// `nonisolated static` so unit tests can call it without an actor hop or a loaded model.
    ///
    /// - Parameter messages: ordered conversation, optionally starting with one system message
    /// - Returns:
    ///   - `instructions`: the system prompt (or `nil`) to pass as `ChatSession.instructions`
    ///   - `history`: prior user/assistant turns to pass as `ChatSession.history` (system
    ///     messages are never included — `instructions` already prepends one)
    ///   - `latestUserMessage`: the final user turn that triggers generation
    /// - Throws: `MLXInferenceError.modelNotLoaded` if the message list is empty or the
    ///   final entry isn't a user turn (we have no other error to map it to today)
    nonisolated static func buildSessionInputs(
        from messages: [(role: String, content: String)]
    ) throws -> (instructions: String?, history: [Chat.Message], latestUserMessage: String) {
        let instructions = messages.first(where: { $0.role == "system" })?.content
        let turns = messages.filter { $0.role != "system" }
        guard let last = turns.last, last.role == "user" else {
            throw MLXInferenceError.modelNotLoaded
        }
        let history: [Chat.Message] = turns.dropLast().map { turn in
            switch turn.role {
            case "assistant": return .assistant(turn.content)
            // Unknown roles are coerced to user (defensive — not expected in practice).
            default: return .user(turn.content)
            }
        }
        return (instructions, history, last.content)
    }

    // MARK: - Generate

    /// Generates a complete response (non-streaming).
    func generate(
        messages: [(role: String, content: String)],
        config: GenerationConfig = .default
    ) async throws -> String {
        guard let container = modelContainer else {
            throw MLXInferenceError.modelNotLoaded
        }
        guard !isGenerating else { throw MLXInferenceError.busy }
        isGenerating = true
        defer { isGenerating = false }

        let (instructions, history, latestUserMessage) =
            try Self.buildSessionInputs(from: messages)

        let params = GenerateParameters(
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            topP: config.topP,
            repetitionPenalty: config.repetitionPenalty
        )

        // Fresh session every call. The history seeded here is the *real* conversation;
        // prefill happens lazily on the first respond() call (~100-200ms for 2-3 turns
        // on a 3B model — imperceptible).
        let session = ChatSession(
            container,
            instructions: instructions,
            history: history,
            generateParameters: params
        )

        return try await session.respond(to: latestUserMessage)
    }

    /// Generates a streaming response. Returns an AsyncThrowingStream of string chunks.
    func generateStream(
        messages: [(role: String, content: String)],
        config: GenerationConfig = .default
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let container = modelContainer else {
            throw MLXInferenceError.modelNotLoaded
        }
        guard !isGenerating else { throw MLXInferenceError.busy }
        isGenerating = true

        // Build inputs synchronously up-front so a malformed messages array fails before
        // the stream is created (callers expect throws here, not via the stream).
        let inputs: (instructions: String?, history: [Chat.Message], latestUserMessage: String)
        do {
            inputs = try Self.buildSessionInputs(from: messages)
        } catch {
            isGenerating = false
            throw error
        }

        let params = GenerateParameters(
            maxTokens: config.maxTokens,
            temperature: config.temperature,
            topP: config.topP,
            repetitionPenalty: config.repetitionPenalty
        )

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let session = ChatSession(
                        container,
                        instructions: inputs.instructions,
                        history: inputs.history,
                        generateParameters: params
                    )
                    // MLX ChatSession.streamResponse yields DELTAS (just the new tokens).
                    // We accumulate and yield CUMULATIVE strings so ResultView can consume
                    // them uniformly — matching Apple FoundationModels' `partial.content` format.
                    let stream = session.streamResponse(to: inputs.latestUserMessage)
                    var accumulated = ""
                    for try await delta in stream {
                        accumulated += delta
                        continuation.yield(accumulated)
                    }
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
