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

    func testSummarizeSystemPromptForbidsMarkdown() {
        let (system, _) = LLMService.prompts(
            for: .summarize,
            text: "test",
            appContext: nil
        )
        // Regression guard: Summarize output flows through ResultView's inline-only
        // markdown renderer, so block-level markdown (#, -, [ ]) leaks as raw text
        // into the view and the clipboard. The prompt must forbid it.
        XCTAssertTrue(system.lowercased().contains("markdown"),
                      "Summarize system prompt should explicitly forbid markdown")
    }

    func testSummarizeUsesUnicodeBullets() {
        let (system, _) = LLMService.prompts(
            for: .summarize,
            text: "test",
            appContext: nil
        )
        // Regression guard: Summarize must use Unicode bullet (•), not markdown
        // hyphens. Unicode bullets render correctly AND copy cleanly to the
        // clipboard; markdown `- item` leaks raw characters in both places.
        XCTAssertTrue(system.contains("\u{2022}"),
                      "Summarize should instruct the model to use Unicode bullet •, not markdown -")
    }

    func testExplainSystemPromptForbidsMarkdown() {
        let (system, _) = LLMService.prompts(
            for: .explain,
            text: "test",
            appContext: nil
        )
        XCTAssertTrue(system.lowercased().contains("markdown"),
                      "Explain system prompt should explicitly forbid markdown")
    }

    func testCustomSystemPromptForbidsMarkdown() {
        let (system, _) = LLMService.prompts(
            for: .custom("do something"),
            text: "test",
            appContext: nil
        )
        XCTAssertTrue(system.lowercased().contains("markdown"),
                      "Custom action system prompt should explicitly forbid markdown")
    }

    // MARK: - buildMessages (Context Snippets + About You injection)

    /// Regression guard: without snippet or About You, the helper returns a
    /// bare system prompt (matches pre-Context-Snippets behavior).
    func testBuildMessagesNeitherInjection() {
        let messages = LLMService.buildMessages(
            systemPrompt: "You are a summarizer.",
            userPrompt: "Summarize this.",
            aboutYou: "",
            snippet: nil
        )

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertEqual(messages[0].content, "You are a summarizer.")
        XCTAssertEqual(messages[1].role, "user")
        XCTAssertEqual(messages[1].content, "Summarize this.")
    }

    /// Regression guard: "About You" alone still works (existing behavior).
    func testBuildMessagesAboutYouOnly() {
        let messages = LLMService.buildMessages(
            systemPrompt: "You are a summarizer.",
            userPrompt: "Summarize this.",
            aboutYou: "I'm a Rails developer.",
            snippet: nil
        )

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].content.hasPrefix("About the user: I'm a Rails developer."),
                      "About You should be prepended to the system prompt")
        XCTAssertTrue(messages[0].content.hasSuffix("You are a summarizer."),
                      "Action system prompt should still be present after About You")
    }

    /// New behavior: snippet alone (no About You) injects the `[App context: X]` section.
    func testBuildMessagesSnippetOnly() {
        let snippet = ContextSnippet(
            bundleId: "com.apple.Terminal",
            appName: "Terminal",
            context: "Ruby/Rails debugging context.",
            enabled: true
        )

        let messages = LLMService.buildMessages(
            systemPrompt: "You are a summarizer.",
            userPrompt: "Summarize this.",
            aboutYou: "",
            snippet: snippet
        )

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].content.contains("[App context: Terminal]"),
                      "Structured label must appear for small-model section awareness")
        XCTAssertTrue(messages[0].content.contains("Ruby/Rails debugging context."),
                      "Snippet context should be in the system prompt")
        XCTAssertTrue(messages[0].content.contains("You are a summarizer."),
                      "Action system prompt should still be present")
        XCTAssertFalse(messages[0].content.contains("About the user"),
                       "About You should not appear when empty")
    }

    /// New behavior: snippet + About You both present, with correct layering.
    /// Order (outer → inner): About You → [App context] → system prompt.
    func testBuildMessagesSnippetAndAboutYou() {
        let snippet = ContextSnippet(
            bundleId: "com.apple.Terminal",
            appName: "Terminal",
            context: "Ruby/Rails debugging context.",
            enabled: true
        )

        let messages = LLMService.buildMessages(
            systemPrompt: "You are a summarizer.",
            userPrompt: "Summarize this.",
            aboutYou: "I'm a backend engineer.",
            snippet: snippet
        )

        let systemContent = messages[0].content

        // Verify both sections are present
        XCTAssertTrue(systemContent.contains("About the user: I'm a backend engineer."))
        XCTAssertTrue(systemContent.contains("[App context: Terminal]"))
        XCTAssertTrue(systemContent.contains("Ruby/Rails debugging context."))
        XCTAssertTrue(systemContent.contains("You are a summarizer."))

        // Verify ordering — About You first, then App context, then action prompt
        let aboutRange = systemContent.range(of: "About the user:")!
        let appContextRange = systemContent.range(of: "[App context:")!
        let actionPromptRange = systemContent.range(of: "You are a summarizer.")!

        XCTAssertLessThan(aboutRange.lowerBound, appContextRange.lowerBound,
                          "About You must come before the App context section")
        XCTAssertLessThan(appContextRange.lowerBound, actionPromptRange.lowerBound,
                          "App context must come before the action system prompt")
    }

    // MARK: - LLMService.buildFollowUpSystemPrompt

    /// The conversational core of the follow-up prompt. Used as a marker so tests can
    /// verify the core is present without binding to its exact wording. Update this
    /// constant if the core string changes.
    private static let followUpCoreMarker = "continuing a conversation"

    func testFollowUpPromptIsConversationalAndForbidsMarkdown() {
        let prompt = LLMService.buildFollowUpSystemPrompt(aboutYou: "", snippet: nil)
        XCTAssertTrue(prompt.contains(Self.followUpCoreMarker),
                      "Follow-up prompt should contain the conversational core")
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("Output only"),
                       "Follow-up prompt must NOT contain 'Output only' — that's the action-specific framing we're swapping away from")
        XCTAssertTrue(prompt.contains("no markdown"),
                      "Follow-up prompt must forbid markdown to match project policy")
    }

    func testFollowUpPromptOmitsAboutYouWhenEmpty() {
        let prompt = LLMService.buildFollowUpSystemPrompt(aboutYou: "", snippet: nil)
        XCTAssertFalse(prompt.contains("About the user:"),
                       "Empty aboutYou must not inject the About the user header")
    }

    func testFollowUpPromptInjectsAboutYouWhenPresent() {
        let prompt = LLMService.buildFollowUpSystemPrompt(
            aboutYou: "I prefer metric units.",
            snippet: nil
        )
        XCTAssertTrue(prompt.contains("About the user: I prefer metric units."),
                      "Non-empty aboutYou must be wrapped with the standard header")
    }

    func testFollowUpPromptOmitsSnippetWhenNil() {
        let prompt = LLMService.buildFollowUpSystemPrompt(
            aboutYou: "Whatever",
            snippet: nil
        )
        XCTAssertFalse(prompt.contains("[App context:"),
                       "Nil snippet must not inject the App context header")
    }

    func testFollowUpPromptInjectsContextSnippet() {
        let snippet = ContextSnippet(
            bundleId: "com.apple.Terminal",
            appName: "Terminal",
            context: "Ruby/Rails debugging context."
        )
        let prompt = LLMService.buildFollowUpSystemPrompt(
            aboutYou: "",
            snippet: snippet
        )
        XCTAssertTrue(prompt.contains("[App context: Terminal]"),
                      "Snippet must inject an [App context: …] header with the appName")
        XCTAssertTrue(prompt.contains("Ruby/Rails debugging context."),
                      "Snippet body must be present")
    }

    func testFollowUpPromptWrappingOrderMatchesBuildMessages() {
        // Mirror the buildMessages contract: About You outermost → App context middle →
        // conversational core innermost. Locks in the ordering invariant so a future
        // refactor can't accidentally flip the layers.
        let snippet = ContextSnippet(
            bundleId: "com.apple.Terminal",
            appName: "Terminal",
            context: "Ruby/Rails debugging context."
        )
        let prompt = LLMService.buildFollowUpSystemPrompt(
            aboutYou: "I'm a backend engineer.",
            snippet: snippet
        )

        let aboutRange = prompt.range(of: "About the user:")!
        let appContextRange = prompt.range(of: "[App context:")!
        let coreRange = prompt.range(of: Self.followUpCoreMarker)!

        XCTAssertLessThan(aboutRange.lowerBound, appContextRange.lowerBound,
                          "About You must come before the App context section")
        XCTAssertLessThan(appContextRange.lowerBound, coreRange.lowerBound,
                          "App context must come before the conversational core")
    }

    func testBuildMessagesDoesNotInjectFollowUpPrompt() {
        // Regression guard: buildMessages is for turn-1 only and must NEVER auto-inject
        // the conversational follow-up prompt. The system prompt swap belongs to the
        // caller (ActionListWindow.submitFollowUp). If this guarantee changes, the
        // wrapping order in buildFollowUpSystemPrompt needs to be re-audited.
        let messages = LLMService.buildMessages(
            systemPrompt: "Output only the summary.",
            userPrompt: "test",
            aboutYou: "",
            snippet: nil
        )
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertTrue(messages[0].content.contains("Output only the summary"))
        XCTAssertFalse(messages[0].content.contains(Self.followUpCoreMarker),
                       "buildMessages must not inject the follow-up conversational core")
    }
}
