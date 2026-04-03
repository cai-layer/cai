import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - MLX Inference Service

/// In-process LLM inference via MLX-Swift. Replaces the llama-server subprocess.
/// Loads MLX-format models from disk or HuggingFace and runs inference natively on Apple Silicon.
actor MLXInference {

    static let shared = MLXInference()

    // MARK: - State

    private var modelContainer: ModelContainer?

    /// Whether a model is currently loaded and ready for inference.
    var isLoaded: Bool { modelContainer != nil }

    // MARK: - Default Model

    /// Default model for first-time setup.
    static let defaultModelId = "mlx-community/Ministral-3-3B-Instruct-2512-4bit"

    /// Curated models for the settings picker.
    static let curatedModels: [(id: String, name: String, size: String)] = [
        ("mlx-community/Ministral-3-3B-Instruct-2512-4bit", "Ministral 3B", "~1.8 GB"),
        ("mlx-community/Qwen3-4B-4bit", "Qwen3 4B", "~2.5 GB"),
        ("mlx-community/gemma-3-1b-it-qat-4bit", "Gemma 3 1B", "~0.8 GB"),
    ]

    // MARK: - Load Model

    /// Loads an MLX model from a local directory (already downloaded).
    func loadModel(from directory: URL) async throws {
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
        print("🧠 MLX downloading model: \(id)")
        let container = try await loadModelContainer(
            id: id,
            progressHandler: progressHandler
        )
        self.modelContainer = container
        print("🧠 MLX model \(id) loaded successfully")
    }

    // MARK: - Generate

    /// Generates a complete response (non-streaming). Used by external callers that expect a full string.
    func generate(
        messages: [(role: String, content: String)],
        temperature: Float = 0.3,
        maxTokens: Int = 1024
    ) async throws -> String {
        guard let container = modelContainer else {
            throw MLXInferenceError.modelNotLoaded
        }

        let systemPrompt = messages.first(where: { $0.role == "system" })?.content
        let userMessage = messages.last(where: { $0.role == "user" })?.content ?? ""

        // Create a fresh ChatSession per generation (Cai uses single-turn conversations)
        let params = GenerateParameters(maxTokens: maxTokens, temperature: temperature, topP: 0.9)
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: params
        )

        return try await session.respond(to: userMessage)
    }

    /// Generates a streaming response. Returns an AsyncThrowingStream of string chunks.
    func generateStream(
        messages: [(role: String, content: String)],
        temperature: Float = 0.3,
        maxTokens: Int = 1024
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let container = modelContainer else {
            throw MLXInferenceError.modelNotLoaded
        }

        let systemPrompt = messages.first(where: { $0.role == "system" })?.content
        let userMessage = messages.last(where: { $0.role == "user" })?.content ?? ""

        let params = GenerateParameters(maxTokens: maxTokens, temperature: temperature, topP: 0.9)
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: params
        )

        return session.streamResponse(to: userMessage)
    }

    // MARK: - Lifecycle

    /// Unloads the model and frees memory.
    func unload() {
        modelContainer = nil
        print("🧠 MLX model unloaded")
    }
}

// MARK: - Errors

enum MLXInferenceError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No AI model is loaded. Please download a model in Settings."
        }
    }
}
