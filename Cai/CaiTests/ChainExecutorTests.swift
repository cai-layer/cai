import CaiActionCore
import XCTest
@testable import Cai

/// Tests for `ChainExecutor` — the action chain orchestrator.
///
/// **Scope:**
/// - Lookup: empty chain, unknown action, invalid inline LLM step.
/// - Output propagation: single shell stdout, two-step pipe via stdin,
///   `tee`-style destinations (covered manually — see comment in test).
/// - Recursive `next:`: a child action's `next:` runs before parent's
///   next sibling.
/// - Safety: cycle detection (action steps only), max-depth cap,
///   step failure aborts.
/// - Inline LLM step: empty directive validation. Real LLM calls covered
///   manually via smoke flow (would need LLM mocking otherwise).
/// - Apple Shortcut step: validation. Real `shortcuts run` calls covered
///   manually (host-machine dependent).
///
/// All tests inject a closure-based `Resolver` so they don't touch
/// `CaiSettings.shared`. Shell shortcuts spawn `/bin/zsh -c` subprocesses,
/// so each test costs ~50–200ms; the suite stays under ~2s end-to-end.
@MainActor
final class ChainExecutorTests: XCTestCase {

    // MARK: - Helpers

    private func shellShortcut(_ name: String, value: String, next: [ChainStep] = []) -> CaiShortcut {
        CaiShortcut(name: name, type: .shell, value: value, next: next)
    }

    private func resolver(_ map: [String: CaiShortcut]) -> ChainExecutor.Resolver {
        return { name in map[name].map { .shortcut($0) } }
    }

    /// Resolver over a mixed map of shortcuts and destinations, for the
    /// terminal-step tests.
    private func mixedResolver(
        shortcuts: [String: CaiShortcut] = [:],
        destinations: [String: OutputDestination] = [:]
    ) -> ChainExecutor.Resolver {
        return { name in
            if let s = shortcuts[name] { return .shortcut(s) }
            if let d = destinations[name] { return .destination(d) }
            return nil
        }
    }

    private func clipboardDestination(_ name: String, next: [ChainStep] = []) -> OutputDestination {
        OutputDestination(
            name: name, icon: "doc.on.clipboard", type: .clipboardCopy,
            isBuiltIn: true, next: next
        )
    }

    /// Convenience: wrap action names as `.action(name:)` steps.
    private func actions(_ names: String...) -> [ChainStep] {
        names.map { .action(name: $0) }
    }

    // MARK: - Empty / lookup

    func testEmptyChainReturnsInitialInputUnchanged() async throws {
        let executor = ChainExecutor(resolver: { _ in nil })
        let out = try await executor.executeForTesting(steps: [], initialInput: "hello")
        XCTAssertEqual(out, "hello")
    }

    func testUnknownActionThrows() async {
        let executor = ChainExecutor(resolver: { _ in nil })
        do {
            _ = try await executor.executeForTesting(steps: actions("missing"), initialInput: "x")
            XCTFail("expected unknownAction")
        } catch ChainExecutor.ChainError.unknownAction(let name) {
            XCTAssertEqual(name, "missing")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Output propagation

    func testSingleShellPropagatesStdout() async throws {
        let echo = shellShortcut("Echo", value: "printf 'hi from echo'")
        let executor = ChainExecutor(resolver: resolver(["Echo": echo]))
        let out = try await executor.executeForTesting(steps: actions("Echo"), initialInput: "ignored")
        XCTAssertEqual(out, "hi from echo")
    }

    func testTwoShellChainPipesStdoutAsStdin() async throws {
        // `cat` reads stdin (fed by ChainExecutor with previous step's output)
        // and prints it, so S2 should receive S1's stdout — proving the
        // in-memory pipe is wired correctly.
        let s1 = shellShortcut("S1", value: "printf 'step1'")
        let s2 = shellShortcut("S2", value: "cat")
        let executor = ChainExecutor(resolver: resolver(["S1": s1, "S2": s2]))
        let out = try await executor.executeForTesting(steps: actions("S1", "S2"), initialInput: "initial")
        XCTAssertEqual(out, "step1")
    }

    // MARK: - Recursive next:

    func testActionNextRunsBeforeNextSibling() async throws {
        // Sibling chain [A, C], where A has next: [B]
        // Expected execution order: A → B → C (depth-first)
        // - A prints "A"
        // - B reads stdin "A" via `cat` and appends "B" → "AB"
        // - C reads stdin "AB" via `cat` and appends "C" → "ABC"
        let a = shellShortcut("A", value: "printf 'A'", next: actions("B"))
        let b = shellShortcut("B", value: "cat && printf 'B'")
        let c = shellShortcut("C", value: "cat && printf 'C'")
        let executor = ChainExecutor(resolver: resolver(["A": a, "B": b, "C": c]))
        let out = try await executor.executeForTesting(steps: actions("A", "C"), initialInput: "init")
        XCTAssertEqual(out, "ABC")
    }

    // MARK: - Safety: cycle detection

    func testCycleDetected() async {
        // A → B → A: visited-set check should catch the second visit to A.
        let a = shellShortcut("A", value: "printf 'a'", next: actions("B"))
        let b = shellShortcut("B", value: "printf 'b'", next: actions("A"))
        let executor = ChainExecutor(resolver: resolver(["A": a, "B": b]))
        do {
            _ = try await executor.executeForTesting(steps: actions("A"), initialInput: "x")
            XCTFail("expected cycle")
        } catch ChainExecutor.ChainError.cycle(let detected, _) {
            XCTAssertEqual(detected, "A")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Safety: max depth

    func testMaxDepthExceededThrows() async {
        // Build a 12-deep linear chain (A1 → A2 → ... → A12).
        // maxDepth = 10, so A11 never runs — recursion to depth 11 throws
        // before invoking the step.
        let names = (1...12).map { "A\($0)" }
        var map: [String: CaiShortcut] = [:]
        for i in 0..<names.count {
            let nextSteps: [ChainStep] = i + 1 < names.count ? [.action(name: names[i + 1])] : []
            map[names[i]] = shellShortcut(names[i], value: "printf 'step'", next: nextSteps)
        }
        let executor = ChainExecutor(resolver: resolver(map))
        do {
            _ = try await executor.executeForTesting(steps: [.action(name: names[0])], initialInput: "x")
            XCTFail("expected tooDeep")
        } catch ChainExecutor.ChainError.tooDeep(let max) {
            XCTAssertEqual(max, ChainExecutor.maxDepth)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Safety: failure aborts chain

    func testStepFailureAbortsChainAndNamesFailingStep() async {
        // S1 succeeds; S2 fails (nonexistent command); S3 must not run.
        let s1 = shellShortcut("S1", value: "printf 'ok'")
        let s2 = shellShortcut("S2", value: "definitely_not_a_real_command_zzz")
        let s3 = shellShortcut("S3", value: "printf 'should not see'")
        let executor = ChainExecutor(resolver: resolver(["S1": s1, "S2": s2, "S3": s3]))
        do {
            _ = try await executor.executeForTesting(steps: actions("S1", "S2", "S3"), initialInput: "x")
            XCTFail("expected stepFailed")
        } catch ChainExecutor.ChainError.stepFailed(let action, _) {
            XCTAssertEqual(action, "S2")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Inline LLM step validation
    //
    // Real LLM calls are covered manually via the smoke flow (would require
    // mocking LLMService.shared and would be flaky on machines without a
    // loaded model). Here we just verify the empty-directive guard fires
    // BEFORE any LLM call, matching the engine's `|llm` filter validation.

    func testInlineLLMWithEmptyDirectiveThrows() async {
        let executor = ChainExecutor(resolver: { _ in nil })
        do {
            _ = try await executor.executeForTesting(
                steps: [.inlineLLM(directive: "")],
                initialInput: "x"
            )
            XCTFail("expected invalidStep")
        } catch ChainExecutor.ChainError.invalidStep {
            // Empty-directive guard fires before any LLM call.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testInlineLLMWithWhitespaceOnlyDirectiveThrows() async {
        let executor = ChainExecutor(resolver: { _ in nil })
        do {
            _ = try await executor.executeForTesting(
                steps: [.inlineLLM(directive: "   \n\t  ")],
                initialInput: "x"
            )
            XCTFail("expected invalidStep")
        } catch ChainExecutor.ChainError.invalidStep {
            // Whitespace-only directive treated as empty.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Cycle detection scope
    //
    // Cycle detection only applies to `.action` steps (those are the only
    // ones that can recurse via their own `next:`). Inline LLM and Apple
    // Shortcut steps can repeat in a chain without triggering the cycle
    // guard, since they're leaf step types.

    func testInlineLLMStepsDoNotTriggerCycleDetection() async throws {
        // Two identical inline LLM steps in a row — would trigger the cycle
        // detector if it tracked all step types. Only fails because the
        // empty-directive validation fires on the first step (we use empty
        // so we don't need to mock the LLM).
        // We assert the failure is `invalidStep` (not `cycle`) — proves the
        // cycle detector didn't trip.
        let executor = ChainExecutor(resolver: { _ in nil })
        do {
            _ = try await executor.executeForTesting(
                steps: [.inlineLLM(directive: ""), .inlineLLM(directive: "")],
                initialInput: "x"
            )
            XCTFail("expected invalidStep")
        } catch ChainExecutor.ChainError.invalidStep {
            // First step's empty-directive guard fires, not cycle.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Codable for ChainStep
    //
    // Round-trip a ChainStep enum through Codable to lock the wire format
    // — guards against accidental changes to the encoder that would break
    // persisted user chains.

    func testChainStepCodableRoundTripActionCase() throws {
        let original: ChainStep = .action(name: "Send to Slack")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChainStep.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testChainStepCodableRoundTripInlineLLMCase() throws {
        let original: ChainStep = .inlineLLM(directive: "summarize as one bullet")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChainStep.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testChainStepCodableRoundTripAppleShortcutCase() throws {
        let original: ChainStep = .appleShortcut(name: "Add to Reminders")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChainStep.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - ExtensionParser.parseNext (YAML chain steps)
    //
    // These tests live here (rather than in a dedicated ExtensionParserTests
    // file) because they're tightly coupled to ChainStep semantics. Adding a
    // new test file requires 4 edits to project.pbxproj — appending to this
    // chain-themed test class is the lower-risk path with the same coverage.

    func testParseNextReturnsEmptyForNilInput() {
        XCTAssertTrue(ExtensionParser.parseNext(nil).isEmpty)
    }

    func testParseNextReturnsEmptyForWrongShape() {
        // String, dict, and number all should return [] (defensive parsing —
        // a malformed `next:` field should never crash the parse).
        XCTAssertTrue(ExtensionParser.parseNext("not an array").isEmpty)
        XCTAssertTrue(ExtensionParser.parseNext(["wrong shape": "value"]).isEmpty)
        XCTAssertTrue(ExtensionParser.parseNext(42).isEmpty)
    }

    func testParseNextActionKeyParsesAsActionCase() {
        let raw: [[String: Any]] = [["action": "Reformat as bullets"]]
        let steps = ExtensionParser.parseNext(raw)
        XCTAssertEqual(steps, [.action(name: "Reformat as bullets")])
    }

    func testParseNextDestinationKeyAliasesToActionCase() {
        // `destination:` is a semantic alias for `action:` — both produce
        // .action(name:) since ChainExecutor resolves shortcuts and
        // destinations from the same name space.
        let raw: [[String: Any]] = [["destination": "Send to Slack"]]
        let steps = ExtensionParser.parseNext(raw)
        XCTAssertEqual(steps, [.action(name: "Send to Slack")])
    }

    func testParseNextLLMKeyParsesAsInlineLLMCase() {
        let raw: [[String: Any]] = [["llm": "Make it more formal"]]
        let steps = ExtensionParser.parseNext(raw)
        XCTAssertEqual(steps, [.inlineLLM(directive: "Make it more formal")])
    }

    func testParseNextAppleShortcutKeyParsesAsAppleShortcutCase() {
        let raw: [[String: Any]] = [["apple_shortcut": "Send to Telegram"]]
        let steps = ExtensionParser.parseNext(raw)
        XCTAssertEqual(steps, [.appleShortcut(name: "Send to Telegram")])
    }

    func testParseNextMixedSequencePreservesOrder() {
        let raw: [[String: Any]] = [
            ["action": "Format"],
            ["llm": "Translate"],
            ["destination": "Slack"],
            ["apple_shortcut": "Notify"]
        ]
        let steps = ExtensionParser.parseNext(raw)
        XCTAssertEqual(steps, [
            .action(name: "Format"),
            .inlineLLM(directive: "Translate"),
            .action(name: "Slack"),
            .appleShortcut(name: "Notify")
        ])
    }

    func testParseNextSilentlySkipsUnknownKeys() {
        let raw: [[String: Any]] = [
            ["action": "Valid"],
            ["unknown_key": "Skipped"],
            ["llm": "Also valid"]
        ]
        let steps = ExtensionParser.parseNext(raw)
        XCTAssertEqual(steps, [.action(name: "Valid"), .inlineLLM(directive: "Also valid")])
    }

    func testParseNextSilentlySkipsEmptyValues() {
        // Empty/whitespace-only strings are treated as "no value" — skipped
        // rather than producing an empty-named step that would never resolve.
        let raw: [[String: Any]] = [
            ["action": ""],
            ["action": "   "],
            ["llm": ""],
            ["action": "Real one"]
        ]
        let steps = ExtensionParser.parseNext(raw)
        XCTAssertEqual(steps, [.action(name: "Real one")])
    }

    // MARK: - ExtensionParser.emitChainYAML

    func testEmitChainYAMLEmptyChainProducesEmptyString() {
        let yaml = ExtensionParser.emitChainYAML([], destinationNames: [])
        XCTAssertEqual(yaml, "")
    }

    func testEmitChainYAMLActionWithoutLocalDestinationMatchEmitsActionKey() {
        // No destination named "Format" exists locally → emit `action:` (the
        // import-side parser will route it to .action(name:) regardless).
        let yaml = ExtensionParser.emitChainYAML(
            [.action(name: "Format")],
            destinationNames: ["Email", "Notes"]
        )
        XCTAssertTrue(yaml.contains("action: \"Format\""), "Expected `action:` key, got: \(yaml)")
    }

    func testEmitChainYAMLActionMatchingLocalDestinationEmitsDestinationKey() {
        // "Send to Slack" exists in destinationNames → emit semantically
        // correct `destination:` key.
        let yaml = ExtensionParser.emitChainYAML(
            [.action(name: "Send to Slack")],
            destinationNames: ["Send to Slack", "Email"]
        )
        XCTAssertTrue(yaml.contains("destination: \"Send to Slack\""), "Expected `destination:` key, got: \(yaml)")
    }

    func testEmitChainYAMLInlineLLMEmitsLLMKey() {
        let yaml = ExtensionParser.emitChainYAML(
            [.inlineLLM(directive: "Make it formal")],
            destinationNames: []
        )
        XCTAssertTrue(yaml.contains("llm: \"Make it formal\""), "Expected `llm:` key, got: \(yaml)")
    }

    func testEmitChainYAMLAppleShortcutEmitsAppleShortcutKey() {
        let yaml = ExtensionParser.emitChainYAML(
            [.appleShortcut(name: "Notify family")],
            destinationNames: []
        )
        XCTAssertTrue(yaml.contains("apple_shortcut: \"Notify family\""), "Expected `apple_shortcut:` key, got: \(yaml)")
    }

    // MARK: - Round-trip: emit → parse should yield identical chain

    func testEmitParseRoundTripPreservesChain() throws {
        let original: [ChainStep] = [
            .action(name: "Local Action"),
            .inlineLLM(directive: "Be concise"),
            .action(name: "Local Destination"),     // resolves as destination on emit
            .appleShortcut(name: "Apple Notify")
        ]
        let yaml = ExtensionParser.emitChainYAML(
            original,
            destinationNames: ["Local Destination"]
        )

        // Re-parse via the full ExtensionParser flow (Yams + parseNext) by
        // wrapping the emitted `next:` block in a minimal valid extension.
        let fullYAML = """
        # cai-extension
        name: Round Trip Test
        type: prompt
        prompt: "irrelevant"\(yaml)
        """
        let parsed = try ExtensionParser.parse(fullYAML)
        guard case .shortcut(let shortcut, _, _) = parsed else {
            XCTFail("Expected shortcut, got destination")
            return
        }
        XCTAssertEqual(shortcut.next, original)
    }

    // MARK: - Backward compat: extensions without `next:` still parse

    func testExtensionWithoutNextFieldYieldsEmptyChain() throws {
        let yaml = """
        # cai-extension
        name: No Chain
        type: prompt
        prompt: "Just a prompt"
        """
        let parsed = try ExtensionParser.parse(yaml)
        guard case .shortcut(let shortcut, _, _) = parsed else {
            XCTFail("Expected shortcut")
            return
        }
        XCTAssertTrue(shortcut.next.isEmpty)
    }

    // MARK: - Built-in action chainability
    //
    // End-to-end LLM dispatch isn't covered here (would need to mock
    // LLMService); these tests pin down the chainability contract and the
    // `ResolvedAction.builtIn` shape that `runAction` switches on.

    func testIsChainableTrueForLLMTransforms() {
        // The five LLM-powered transforms should be chain-eligible.
        XCTAssertTrue(BuiltInActionID.summarize.isChainable)
        XCTAssertTrue(BuiltInActionID.explain.isChainable)
        XCTAssertTrue(BuiltInActionID.reply.isChainable)
        XCTAssertTrue(BuiltInActionID.proofread.isChainable)
        XCTAssertTrue(BuiltInActionID.translate.isChainable)
    }

    func testIsChainableFalseForSideEffectsAndUIActions() {
        // External side-effect actions can't continue a chain (no text out).
        XCTAssertFalse(BuiltInActionID.openURL.isChainable)
        XCTAssertFalse(BuiltInActionID.openMaps.isChainable)
        XCTAssertFalse(BuiltInActionID.createEvent.isChainable)
        XCTAssertFalse(BuiltInActionID.searchWeb.isChainable)
        // Ask AI is a UI dialog; Define Word requires single-word input;
        // Pretty Print JSON is non-LLM (deferred).
        XCTAssertFalse(BuiltInActionID.askAI.isChainable)
        XCTAssertFalse(BuiltInActionID.defineWord.isChainable)
        XCTAssertFalse(BuiltInActionID.prettyPrint.isChainable)
    }

    func testToLLMActionMapsChainableCases() async {
        let summarize = await MainActor.run { BuiltInActionID.summarize.toLLMAction() }
        if case .summarize = summarize { /* pass */ } else {
            XCTFail("Expected .summarize, got \(String(describing: summarize))")
        }
        let proofread = await MainActor.run { BuiltInActionID.proofread.toLLMAction() }
        if case .proofread = proofread { /* pass */ } else {
            XCTFail("Expected .proofread, got \(String(describing: proofread))")
        }
        // Translate carries the user's preferred language.
        let translate = await MainActor.run { BuiltInActionID.translate.toLLMAction() }
        if case .translate = translate { /* pass */ } else {
            XCTFail("Expected .translate(...), got \(String(describing: translate))")
        }
    }

    func testToLLMActionReturnsNilForNonChainable() async {
        let askAI = await MainActor.run { BuiltInActionID.askAI.toLLMAction() }
        XCTAssertNil(askAI)
        let openURL = await MainActor.run { BuiltInActionID.openURL.toLLMAction() }
        XCTAssertNil(openURL)
    }

    func testResolvedActionBuiltInHasEmptyNextAndDisplayLabelName() {
        let resolved = ChainExecutor.ResolvedAction.builtIn(.summarize)
        XCTAssertEqual(resolved.name, "Summarize")
        XCTAssertTrue(resolved.next.isEmpty,
            "Built-ins are leaf transforms — they don't have their own `next:` chain")
    }
}

// MARK: - Terminal step derivation (the default sink)

/// What the default sink routes on: which step *actually ran last*.
///
/// This cannot be read off the top-level step array, because `execute` recurses
/// depth-first into a resolved action's own `next:` AFTER running it. Reading
/// `steps.last` would report a nested LLM step's output as consumed by the
/// destination that preceded it, and drop it — recreating the exact bug the
/// default sink exists to fix. Hence a test, not just a comment.
@MainActor
extension ChainExecutorTests {

    func testTerminalStepIsTheStepThatActuallyRanLast() async throws {
        let echo = shellShortcut("Echo", value: "printf 'text'")
        let cat = shellShortcut("Cat", value: "cat")

        // 1. Chain ending on a text-producing step.
        var executor = ChainExecutor(resolver: resolver(["Echo": echo]))
        var run = try await executor.executeTerminalForTesting(
            steps: actions("Echo"), initialInput: "in"
        )
        XCTAssertEqual(run.terminal, .producesText)

        // 2. Chain ending on a consuming destination.
        executor = ChainExecutor(resolver: mixedResolver(
            shortcuts: ["Echo": echo], destinations: ["Clip": clipboardDestination("Clip")]
        ))
        run = try await executor.executeTerminalForTesting(
            steps: actions("Echo", "Clip"), initialInput: "in"
        )
        XCTAssertEqual(run.terminal, .consumingDestination)

        // 3. THE REGRESSION: the top-level list ends on a destination, but that
        // destination's own `next:` runs a text step afterwards. The output is
        // the text step's, so the terminal must be `.producesText` — otherwise
        // the sink calls it consumed and the text is lost.
        let teeThenText = clipboardDestination("Clip", next: [.action(name: "Cat")])
        executor = ChainExecutor(resolver: mixedResolver(
            shortcuts: ["Echo": echo, "Cat": cat], destinations: ["Clip": teeThenText]
        ))
        run = try await executor.executeTerminalForTesting(
            steps: actions("Echo", "Clip"), initialInput: "in"
        )
        XCTAssertEqual(run.output, "text")
        XCTAssertEqual(run.terminal, .producesText,
                       "a destination's own next: runs after it — that step is the terminal one")

        // 4. "Show in Cai" is a destination that consumes nothing.
        let showInCai = OutputDestination(
            name: "Show in Cai", icon: "macwindow", type: .showInCai,
            isBuiltIn: true, chainOnly: true
        )
        executor = ChainExecutor(resolver: mixedResolver(
            shortcuts: ["Echo": echo], destinations: ["Show in Cai": showInCai]
        ))
        run = try await executor.executeTerminalForTesting(
            steps: actions("Echo", "Show in Cai"), initialInput: "in"
        )
        XCTAssertEqual(run.output, "text", "a no-op destination passes the pipe through")
        XCTAssertEqual(run.terminal, .showInCai)
    }
}
