import XCTest
import MLXLMCommon
@testable import Cai

/// Tests for `MLXInference.buildSessionInputs` — the pure helper that converts
/// Cai's `(role, content)` message tuples into MLX `ChatSession(history:)` inputs.
///
/// These tests don't load a model. The helper is `nonisolated static` specifically
/// so the actor's session-construction contract can be locked in without paying
/// the cost (or environmental complexity) of a real model load.
final class MLXInferenceTests: XCTestCase {

    // MARK: - Helpers

    private func msg(_ role: String, _ content: String) -> (role: String, content: String) {
        (role: role, content: content)
    }

    // MARK: - System prompt extraction

    func testExtractsSystemPrompt() throws {
        let result = try MLXInference.buildSessionInputs(from: [
            msg("system", "You are helpful."),
            msg("user", "hi"),
        ])
        XCTAssertEqual(result.instructions, "You are helpful.")
        XCTAssertEqual(result.history.count, 0,
                       "Single user turn means no prior history")
        XCTAssertEqual(result.latestUserMessage, "hi")
    }

    func testNoSystemPromptYieldsNilInstructions() throws {
        let result = try MLXInference.buildSessionInputs(from: [
            msg("user", "hi"),
        ])
        XCTAssertNil(result.instructions)
        XCTAssertEqual(result.latestUserMessage, "hi")
    }

    // MARK: - History mapping

    func testMapsUserAndAssistantTurnsToHistory() throws {
        let result = try MLXInference.buildSessionInputs(from: [
            msg("system", "sys"),
            msg("user", "first user"),
            msg("assistant", "first assistant"),
            msg("user", "second user"),
            msg("assistant", "second assistant"),
            msg("user", "latest"),
        ])

        XCTAssertEqual(result.instructions, "sys")
        XCTAssertEqual(result.latestUserMessage, "latest")

        XCTAssertEqual(result.history.count, 4)
        XCTAssertEqual(result.history[0].role, .user)
        XCTAssertEqual(result.history[0].content, "first user")
        XCTAssertEqual(result.history[1].role, .assistant)
        XCTAssertEqual(result.history[1].content, "first assistant")
        XCTAssertEqual(result.history[2].role, .user)
        XCTAssertEqual(result.history[2].content, "second user")
        XCTAssertEqual(result.history[3].role, .assistant)
        XCTAssertEqual(result.history[3].content, "second assistant")
    }

    func testSeparatesLatestUserMessageFromHistory() throws {
        // The final user turn must NOT appear in `history` — it's returned separately
        // and passed to ChatSession.respond(to:). Including it in history would cause
        // the model to see the prompt twice.
        let result = try MLXInference.buildSessionInputs(from: [
            msg("user", "old"),
            msg("assistant", "reply"),
            msg("user", "new"),
        ])
        XCTAssertEqual(result.history.count, 2)
        XCTAssertEqual(result.latestUserMessage, "new")
        XCTAssertFalse(result.history.contains(where: { $0.content == "new" }),
                       "Latest user message must not also appear in history")
    }

    func testIgnoresSystemMessagesInHistoryArray() throws {
        // Defensive: even if a stray system message appears mid-conversation (not
        // expected from Cai's call sites, but possible), it must NOT end up in the
        // history array — `instructions` already prepends a system message and
        // duplicating it produces incoherent output.
        let result = try MLXInference.buildSessionInputs(from: [
            msg("system", "first system"),
            msg("user", "u1"),
            msg("system", "stray system"),
            msg("assistant", "a1"),
            msg("user", "latest"),
        ])

        XCTAssertEqual(result.instructions, "first system",
                       "First system message wins as instructions")
        XCTAssertEqual(result.history.count, 2,
                       "Stray system message must not pollute history")
        XCTAssertFalse(result.history.contains(where: { $0.role == .system }),
                       "history must contain no system roles")
    }

    // MARK: - Error cases

    func testThrowsOnEmptyMessages() {
        XCTAssertThrowsError(try MLXInference.buildSessionInputs(from: [])) { error in
            XCTAssertTrue(error is MLXInferenceError)
        }
    }

    func testThrowsWhenLastMessageIsNotUser() {
        // An assistant-final message means the caller is asking the model to "continue
        // their own thought" — Cai never does this. Reject it loudly so a future bug
        // can't silently malform a request.
        XCTAssertThrowsError(try MLXInference.buildSessionInputs(from: [
            msg("user", "hi"),
            msg("assistant", "hello"),
        ])) { error in
            XCTAssertTrue(error is MLXInferenceError)
        }
    }

    func testThrowsWhenOnlySystemMessagePresent() {
        XCTAssertThrowsError(try MLXInference.buildSessionInputs(from: [
            msg("system", "sys"),
        ])) { error in
            XCTAssertTrue(error is MLXInferenceError)
        }
    }
}
