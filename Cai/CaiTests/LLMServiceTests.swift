import XCTest
@testable import Cai

/// Tests for LLMService public/nonisolated surface — GenerationConfig tuning
/// and action prompt templates. Keeps sampling parameters and prompt content
/// locked in so refactors don't silently change LLM behavior.
final class LLMServiceTests: XCTestCase {

    // MARK: - GenerationConfig.forAction

    func testTranslateIsDeterministic() {
        let config = GenerationConfig.forAction(.translate("Spanish"))
        XCTAssertEqual(config.temperature, 0.0,
                       "Translation must be deterministic")
    }

    func testProofreadIsDeterministic() {
        let config = GenerationConfig.forAction(.proofread)
        XCTAssertEqual(config.temperature, 0.0,
                       "Proofreading must be deterministic")
    }

    func testDefineUsesLowTemperature() {
        let config = GenerationConfig.forAction(.define)
        XCTAssertLessThanOrEqual(config.temperature, 0.2,
                                 "Define should use low temperature for factual output")
        XCTAssertLessThanOrEqual(config.maxTokens, 400,
                                 "Define should have a short token budget")
    }

    func testCreativeActionsUseHigherTemperature() {
        let custom = GenerationConfig.forAction(.custom("write a poem"))
        XCTAssertGreaterThanOrEqual(custom.temperature, 0.5,
                                    "Custom prompts should allow creativity")

        let reply = GenerationConfig.forAction(.reply)
        XCTAssertGreaterThanOrEqual(reply.temperature, 0.4,
                                    "Reply should allow tone variation")
    }

    func testRepetitionPenaltyIsNilByDefault() {
        // We intentionally don't set repetition penalty — testing with Ministral 3B
        // showed 1.1 caused token corruption. Regression guard.
        let actions: [LLMAction] = [
            .summarize, .translate("Spanish"), .define,
            .explain, .reply, .proofread, .custom("do something"),
        ]
        for action in actions {
            let config = GenerationConfig.forAction(action)
            XCTAssertNil(config.repetitionPenalty,
                         "\(action) should not set repetitionPenalty (causes token corruption on small models)")
        }
    }

    // MARK: - LLMService.prompts

    func testTranslatePromptIncludesLanguage() {
        let (system, user) = LLMService.prompts(
            for: .translate("German"),
            text: "Hello world",
            appContext: nil
        )
        XCTAssertTrue(user.contains("German") || system.contains("German"),
                      "Translation prompt must specify target language")
        XCTAssertTrue(user.contains("Hello world"))
    }

    func testDefinePromptContainsWord() {
        let (_, user) = LLMService.prompts(
            for: .define,
            text: "ephemeral",
            appContext: nil
        )
        XCTAssertTrue(user.contains("ephemeral"))
    }

    func testAppContextIsInjectedWhenProvided() {
        let (system, _) = LLMService.prompts(
            for: .summarize,
            text: "content",
            appContext: "Slack"
        )
        XCTAssertTrue(system.contains("Slack"),
                      "App context should be injected into system prompt")
    }

    func testAppContextOmittedWhenNil() {
        let (system, _) = LLMService.prompts(
            for: .summarize,
            text: "content",
            appContext: nil
        )
        XCTAssertFalse(system.contains("from "),
                       "System prompt should not contain 'from' when appContext is nil")
    }

    func testReplyPromptUsesTextAsUserMessage() {
        let (_, user) = LLMService.prompts(
            for: .reply,
            text: "Can we reschedule?",
            appContext: nil
        )
        XCTAssertEqual(user, "Can we reschedule?",
                       "Reply should pass the text directly as the user message")
    }

    func testProofreadSystemPromptForbidsMarkdown() {
        let (system, _) = LLMService.prompts(
            for: .proofread,
            text: "test",
            appContext: nil
        )
        // Regression guard: we explicitly tell the model not to use markdown
        // because proofread output goes straight to the clipboard.
        XCTAssertTrue(system.lowercased().contains("markdown"),
                      "Proofread system prompt should explicitly forbid markdown")
    }
}
