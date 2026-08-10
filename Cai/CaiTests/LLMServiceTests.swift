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

    // MARK: - Anthropic API Types

    func testAnthropicRequestEncoding() throws {
        // Verify the request JSON matches Anthropic's /v1/messages format:
        // - system is top-level, not in messages
        // - messages only contain user/assistant roles
        let request = AnthropicRequest(
            model: "claude-sonnet-4-6",
            max_tokens: 1024,
            system: "You are a helpful assistant.",
            messages: [
                AnthropicMessage(role: "user", content: "Hello"),
                AnthropicMessage(role: "assistant", content: "Hi!"),
                AnthropicMessage(role: "user", content: "How are you?"),
            ]
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(json["max_tokens"] as? Int, 1024)
        XCTAssertEqual(json["system"] as? String, "You are a helpful assistant.")
        // No temperature or top_p — Anthropic uses sensible defaults and rejects the combination
        XCTAssertNil(json["temperature"], "temperature must not be sent to avoid top_p conflict")
        XCTAssertNil(json["top_p"], "top_p must not be sent")

        let messages = json["messages"] as! [[String: String]]
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"], "user")
        XCTAssertEqual(messages[1]["role"], "assistant")
        XCTAssertEqual(messages[2]["role"], "user")
        // No system message in the messages array
        XCTAssertTrue(messages.allSatisfy { $0["role"] != "system" })
    }

    func testAnthropicRequestOmitsSystemWhenNil() throws {
        // When no system prompt is set, the JSON should not contain a "system" key
        let request = AnthropicRequest(
            model: "claude-haiku-4-5",
            max_tokens: 512,
            system: nil,
            messages: [AnthropicMessage(role: "user", content: "Hi")]
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Custom encode(to:) omits system key entirely when nil
        XCTAssertNil(json["system"], "system key must be absent when nil — Anthropic rejects null")
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 512)
    }

    // MARK: - Cloud (OpenAI-compatible) Request Types

    func testChatRequestFromConfigForwardsMaxTokensAndOmitsTemperature() throws {
        // Regression guard for #26 (https://github.com/cai-layer/cai/issues/26):
        // the cloud branch previously hardcoded max_tokens: 1024 instead of using
        // the caller's GenerationConfig — max_tokens must be forwarded verbatim.
        // #52: temperature must NOT be sent — some OpenAI-compatible models reject
        // it (mirrors the Anthropic path, which also omits it), even though the
        // config still carries a temperature for the built-in MLX path.
        let config = GenerationConfig(
            temperature: 0.7,
            topP: 0.9,
            maxTokens: 4096,
            repetitionPenalty: nil
        )
        let messages = [ChatMessage(role: "user", content: "Hello")]

        let request = ChatRequest.from(config: config, messages: messages, model: "openrouter/auto")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]

        XCTAssertEqual(request.model, "openrouter/auto")
        XCTAssertNil(json["temperature"],
                     "temperature must not be sent (#52) even though config carries 0.7")
        XCTAssertEqual(json["max_tokens"] as? Int, 4096,
                       "max_tokens must come from config, not hardcoded (#26)")
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages.first?.role, "user")
    }

    func testChatRequestFromConfigUsesProofreadActionDefaults() throws {
        // Verifies the factory composes correctly with GenerationConfig.forAction().
        // Pre-#26, max_tokens would have been silently downgraded to 1024 on the
        // cloud path. (temperature is no longer sent — see #52.)
        let config = GenerationConfig.forAction(.proofread)
        let request = ChatRequest.from(
            config: config,
            messages: [ChatMessage(role: "user", content: "test")],
            model: "google/gemini-2.5-flash"
        )

        XCTAssertEqual(request.max_tokens, 16384,
                       ".proofread maxTokens must reach the cloud request")
    }

    func testChatRequestEncodesAsOpenAICompatibleJSON() throws {
        // Pin the wire format for OpenAI-compatible /v1/chat/completions endpoints
        // (OpenRouter, LM Studio, Ollama, custom). A breaking rename here would
        // silently fail at runtime against every cloud provider.
        let request = ChatRequest(
            model: "test-model",
            messages: [
                ChatMessage(role: "system", content: "You are helpful."),
                ChatMessage(role: "user", content: "Hi"),
            ],
            max_tokens: 2048,
            stream: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["max_tokens"] as? Int, 2048)
        XCTAssertNil(json["temperature"],
                     "temperature must not be sent to OpenAI-compatible endpoints (#52)")

        let messages = json["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are helpful.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "Hi")
    }

    // MARK: - Cloud Streaming (SSE)

    func testChatRequestStreamingFromSetsStreamTrue() throws {
        // The streaming factory must set `stream: true` in the JSON body.
        // OpenAI-compatible servers won't emit SSE without this flag.
        let config = GenerationConfig.forAction(.custom("polish this"))
        let request = ChatRequest.streamingFrom(
            config: config,
            messages: [ChatMessage(role: "user", content: "Hi")],
            model: "openrouter/auto"
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["stream"] as? Bool, true,
                       "streamingFrom must emit stream:true so SSE is enabled")
        // Other fields still forwarded (regression guard for #26 continues to apply).
        XCTAssertEqual(json["max_tokens"] as? Int, 16384)
        XCTAssertEqual(json["model"] as? String, "openrouter/auto")
        XCTAssertNil(json["temperature"],
                     "streaming requests must not send temperature (#52)")
    }

    func testChatRequestFromOmitsStreamKey() throws {
        // Non-streaming factory must NOT emit a `stream` key at all — keeps the
        // wire format identical to pre-streaming for non-streaming callers, and
        // matches the AnthropicRequest pattern of omitting nil fields.
        let config = GenerationConfig.forAction(.proofread)
        let request = ChatRequest.from(
            config: config,
            messages: [ChatMessage(role: "user", content: "Hi")],
            model: "google/gemini-2.5-flash"
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["stream"],
                     "non-streaming factory must not include `stream` in JSON")
    }

    // MARK: - SSE Parser

    func testParseSSELineHandlesContentDelta() throws {
        // Standard OpenAI SSE delta — a single content token.
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        let result = try LLMService.parseSSELine(line)
        XCTAssertEqual(result, .content("Hello"))
    }

    func testParseSSELineHandlesDoneSentinel() throws {
        // OpenAI marks end-of-stream with `data: [DONE]`. Parser must recognize it
        // so the streaming function can finish cleanly.
        let result = try LLMService.parseSSELine("data: [DONE]")
        XCTAssertEqual(result, .done)
    }

    func testParseSSELineSkipsEmptyLine() throws {
        // SSE separates events with blank lines — those must be silently skipped.
        XCTAssertEqual(try LLMService.parseSSELine(""), .skip)
        XCTAssertEqual(try LLMService.parseSSELine("   "), .skip)
    }

    func testParseSSELineSkipsLineWithoutDataPrefix() throws {
        // Comments (lines starting with `:`) and `event:` lines are valid SSE
        // but we don't use them — skip without error.
        XCTAssertEqual(try LLMService.parseSSELine(": ping"), .skip)
        XCTAssertEqual(try LLMService.parseSSELine("event: message"), .skip)
        XCTAssertEqual(try LLMService.parseSSELine("id: 42"), .skip)
    }

    func testParseSSELineSkipsRoleOnlyDelta() throws {
        // OpenAI's first SSE event in a stream carries only the role, no content.
        // Must not error and must not yield empty content.
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        let result = try LLMService.parseSSELine(line)
        XCTAssertEqual(result, .skip,
                       "role-only deltas (no content field) must be skipped")
    }

    func testParseSSELineSkipsEmptyContentDelta() throws {
        // A delta with content="" should not produce a yield (no visible text).
        let line = #"data: {"choices":[{"delta":{"content":""}}]}"#
        let result = try LLMService.parseSSELine(line)
        XCTAssertEqual(result, .skip)
    }

    func testParseSSELineThrowsOnMalformedJSON() {
        // Defensive: a malformed `data:` line should throw, not corrupt the stream.
        let line = "data: {this is not json}"
        XCTAssertThrowsError(try LLMService.parseSSELine(line)) { error in
            guard case LLMError.invalidResponse = error else {
                XCTFail("expected LLMError.invalidResponse, got \(error)")
                return
            }
        }
    }

    func testParseSSELineHandlesDataPrefixWithoutSpace() throws {
        // The SSE spec allows `data:foo` (no space) or `data: foo`. Both must parse.
        let line = #"data:{"choices":[{"delta":{"content":"X"}}]}"#
        let result = try LLMService.parseSSELine(line)
        XCTAssertEqual(result, .content("X"))
    }

    func testParseSSELineHandlesNullContentField() throws {
        // Some providers emit `"content": null` instead of omitting the field.
        // Must be treated identically to a role-only delta.
        let line = #"data: {"choices":[{"delta":{"content":null}}]}"#
        let result = try LLMService.parseSSELine(line)
        XCTAssertEqual(result, .skip)
    }

    func testParseSSELineHandlesEmptyChoicesArray() throws {
        // Some providers send a final SSE event with empty choices (e.g. usage stats).
        // No content → skip without error.
        let line = #"data: {"choices":[]}"#
        let result = try LLMService.parseSSELine(line)
        XCTAssertEqual(result, .skip)
    }

    func testParseSSELineSurfacesObjectErrorEvent() {
        // #52: some OpenAI-compatible servers stream a rejection as an SSE error
        // event on an HTTP 200 (e.g. a model that rejects `temperature`). The parser
        // must surface the real message instead of a generic "invalid response".
        let line = #"data: {"error":{"message":"Unsupported parameter: temperature","type":"invalid_request_error"}}"#
        XCTAssertThrowsError(try LLMService.parseSSELine(line)) { error in
            guard case let LLMError.serverError(_, message) = error else {
                return XCTFail("expected LLMError.serverError, got \(error)")
            }
            XCTAssertEqual(message, "Unsupported parameter: temperature")
        }
    }

    func testParseSSELineSurfacesStringErrorEvent() {
        // The LM Studio shape — {"error": "..."} as a bare string. errorMessage(from:)
        // handles both forms, so this must surface too.
        let line = #"data: {"error":"model is overloaded"}"#
        XCTAssertThrowsError(try LLMService.parseSSELine(line)) { error in
            guard case let LLMError.serverError(_, message) = error else {
                return XCTFail("expected LLMError.serverError, got \(error)")
            }
            XCTAssertEqual(message, "model is overloaded")
        }
    }

    func testParseSSELineErrorEventWithoutMessageDoesNotSurfaceBlank() {
        // An error object with no usable message must not surface a blank
        // "Server error:" — fall through to invalidResponse instead.
        let line = #"data: {"error":{"type":"invalid_request_error"}}"#
        XCTAssertThrowsError(try LLMService.parseSSELine(line)) { error in
            guard case LLMError.invalidResponse = error else {
                return XCTFail("expected LLMError.invalidResponse, got \(error)")
            }
        }
    }

    func testParseSSELineSurfacesErrorEventAlongsideEmptyChoices() {
        // #52: a chunk that decodes (empty `choices`) but also carries an `error`
        // must surface the error, not skip. Token-first decode succeeds here, so the
        // error probe has to run even on a decodable-but-contentless chunk — otherwise
        // the real cause is swallowed and the user sees a generic "empty response".
        let line = #"data: {"choices":[],"error":{"message":"model overloaded"}}"#
        XCTAssertThrowsError(try LLMService.parseSSELine(line)) { error in
            guard case let LLMError.serverError(_, message) = error else {
                return XCTFail("expected LLMError.serverError, got \(error)")
            }
            XCTAssertEqual(message, "model overloaded")
        }
    }

    // MARK: - Endpoint Normalization (issue #28)

    // The endpoint field is a base URL we append `/v1/...` onto. Users paste a
    // bare host, a full base_url ending in `/v1`, a reverse-proxy subpath, or a
    // stray trailing slash. All must normalize so we never build `/v1/v1/...`.

    func testNormalizeBareHostUnchanged() {
        XCTAssertEqual(CaiSettings.normalizedEndpoint("http://127.0.0.1:1234"),
                       "http://127.0.0.1:1234")
    }

    func testNormalizeStripsTrailingV1() {
        // The #28 shape (minus the proxy): user pastes the OpenAI base_url.
        XCTAssertEqual(CaiSettings.normalizedEndpoint("http://127.0.0.1:1234/v1"),
                       "http://127.0.0.1:1234")
    }

    func testNormalizeStripsTrailingV1WithSlash() {
        XCTAssertEqual(CaiSettings.normalizedEndpoint("http://127.0.0.1:1234/v1/"),
                       "http://127.0.0.1:1234")
    }

    func testNormalizePreservesReverseProxySubpath() {
        // The literal #28 endpoint: http://IP:PORT/llama/v1 must resolve to
        // /llama/v1/models, not /llama/v1/v1/models.
        XCTAssertEqual(CaiSettings.normalizedEndpoint("http://10.0.0.5:8080/llama/v1"),
                       "http://10.0.0.5:8080/llama")
    }

    func testNormalizeStripsTrailingSlash() {
        XCTAssertEqual(CaiSettings.normalizedEndpoint("http://127.0.0.1:1234/"),
                       "http://127.0.0.1:1234")
    }

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(CaiSettings.normalizedEndpoint("  http://127.0.0.1:1234/v1  "),
                       "http://127.0.0.1:1234")
    }

    func testNormalizeIsCaseInsensitiveOnV1() {
        XCTAssertEqual(CaiSettings.normalizedEndpoint("http://127.0.0.1:1234/V1"),
                       "http://127.0.0.1:1234")
    }

    func testNormalizeDoesNotStripBareV1Token() {
        // A host merely ending in "v1" (no slash separator) must be left alone.
        XCTAssertEqual(CaiSettings.normalizedEndpoint("http://myv1"),
                       "http://myv1")
    }

    func testNormalizedEndpointProducesSingleV1ModelsPath() {
        // Integration assertion: base + "/v1/models" has exactly one /v1, whatever
        // the user typed. This is the regression that issue #28 is about.
        let inputs = [
            "http://127.0.0.1:1234",
            "http://127.0.0.1:1234/",
            "http://127.0.0.1:1234/v1",
            "http://127.0.0.1:1234/v1/",
        ]
        for input in inputs {
            let resolved = "\(CaiSettings.normalizedEndpoint(input))/v1/models"
            XCTAssertEqual(resolved, "http://127.0.0.1:1234/v1/models",
                           "input \(input) must resolve to a single-/v1 models URL")
        }
    }

    // MARK: - OpenAI-compatible error body extraction (issue #28)

    func testErrorMessageFromStringBody() {
        // LM Studio shape: {"error": "Unexpected endpoint or method. (GET /v1/v1/models)"}
        let json: [String: Any] = ["error": "Unexpected endpoint or method."]
        XCTAssertEqual(LLMService.errorMessage(from: json), "Unexpected endpoint or method.")
    }

    func testErrorMessageFromObjectBody() {
        // OpenAI / OpenRouter shape: {"error": {"message": "...", "type": "..."}}
        let json: [String: Any] = ["error": ["message": "Invalid API key", "type": "auth_error"]]
        XCTAssertEqual(LLMService.errorMessage(from: json), "Invalid API key")
    }

    func testErrorMessageNilWhenAbsent() {
        XCTAssertNil(LLMService.errorMessage(from: ["data": []]))
        XCTAssertNil(LLMService.errorMessage(from: nil))
    }

}
