import AppKit
import CaiActionCore
import Foundation

// MARK: - Chain Executor

/// Runs a sequential chain of Cai actions (`Shortcut.next` / `OutputDestination.next`).
///
/// **Design (locked 2026-05-04):**
/// - Sequential pipe: A → B → C, where each step's output becomes the next
///   step's `{{result}}`.
/// - **NOT routed through the system clipboard.** The chain holds an
///   in-memory pipe value so the user can copy other text mid-chain without
///   breaking the flow. Live clipboard is read once at chain start (the
///   initial pipe value) and never touched again unless an action explicitly
///   writes to it via `pbcopy` etc.
/// - Cycle detection: tracks visited slugs; throws if a cycle is detected.
/// - Max depth: hard cap of 10 steps; throws if exceeded. Catches runaway
///   loops the cycle check might miss (e.g., 50 distinct slugs in a line).
/// - Lookup is by `name`, preferring shortcuts over destinations on collision.
/// - Per-step output convention:
///     - shortcut `.shell`     → stdout (trimmed)
///     - shortcut `.prompt`    → LLM response (trimmed)
///     - shortcut `.url`       → "" (URL was opened; nothing to propagate)
///     - destination of any kind → input passed through unchanged (acts like
///       Unix `tee` — the destination side-effects on the value, but the
///       chain pipe keeps flowing). This lets users fan out the same
///       content to multiple destinations: `[Add Timestamp, Slack, Notes]`
///       sends the timestamped value to BOTH Slack and Notes. The earlier
///       v1 design returned `""` here — that broke the broadcast use case
///       (the second destination got an empty payload).
///   Empty pipe values flow through cleanly; the next step gets "".
/// - MCP form actions are not chainable in v1 (multi-field inputs don't fit
///   the single-pipe model). They can be `next:` *targets* in v2 if demand
///   surfaces, but not v1 sources.
///
/// **Threading:** `@MainActor`-isolated for safe access to `CaiSettings.shared`
/// and notification posting. Long-running work (LLM, shell) hops to background
/// queues internally. Reuses `BackgroundTaskTracker` so the menu bar icon
/// pulses for the duration of the chain (free UX from step 7).
///
/// **Toast UX:** on success, posts `caiShowToast` with the final action's
/// name. On failure, posts a toast naming the failing step + reason. The
/// chain aborts at the first failure; no partial-success retries.
@MainActor
final class ChainExecutor {

    static let shared = ChainExecutor()

    /// Resolves an action name to either a `CaiShortcut` or `OutputDestination`.
    /// The production resolver reads from `CaiSettings.shared`; tests inject a
    /// closure that returns from a known fixture map so they don't depend on
    /// the global singleton's state.
    typealias Resolver = @MainActor (String) -> ResolvedAction?

    private let injectedResolver: Resolver?

    /// Default init wires the production singleton-backed resolver. Tests use
    /// `init(resolver:)` to supply a fixture-backed closure.
    init(resolver: Resolver? = nil) {
        self.injectedResolver = resolver
    }

    /// Hard cap on chain depth. Catches pathological non-cyclic chains
    /// (50+ distinct slugs in a line) and provides belt-and-suspenders
    /// safety against any cycle the visited-set check might miss. Realistic
    /// chains are 2-4 steps; 10 is generous headroom.
    static let maxDepth = 10

    // MARK: - Errors

    enum ChainError: Error, LocalizedError {
        case unknownAction(String)
        case cycle(detected: String, path: [String])
        case tooDeep(maxDepth: Int)
        case stepFailed(action: String, underlying: Error)
        case unsupportedActionType(String)
        /// Step is structurally invalid (e.g., inline LLM with empty
        /// directive). Editor strips these on commit so this should be
        /// unreachable from normal use; thrown as a defensive guard for
        /// hand-edited storage or programmatic mistakes.
        case invalidStep(String)

        var errorDescription: String? {
            switch self {
            case .unknownAction(let name):
                return "Chain step not found: '\(name)'. Check the action name."
            case .cycle(let slug, let path):
                let pathStr = (path + [slug]).joined(separator: " → ")
                return "Chain cycle detected: \(pathStr)"
            case .tooDeep(let max):
                return "Chain exceeded \(max) steps. Possible runaway."
            case .stepFailed(let action, let underlying):
                return "Step '\(action)' failed: \(underlying.localizedDescription)"
            case .unsupportedActionType(let type):
                return "Action type '\(type)' can't be used in a chain (v1)."
            case .invalidStep(let reason):
                return reason
            }
        }
    }

    // MARK: - Resolved action wrapper
    //
    // Lookup happens by `name`. Shortcuts win on collision with destinations,
    // mirroring the action-list dispatch order.
    //
    // Internal (not private) so tests can construct fixtures via `Resolver`.

    enum ResolvedAction {
        case shortcut(CaiShortcut)
        case destination(OutputDestination)
        /// Built-in LLM action (Summarize, Explain, Reply, Fix Grammar, Translate).
        /// Only the chainable subset of `BuiltInActionID` reaches this case —
        /// see `BuiltInActionID.isChainable`. Built-ins have no recursive
        /// `next:` of their own (they're leaf transforms).
        case builtIn(BuiltInActionID)

        var name: String {
            switch self {
            case .shortcut(let s): return s.name
            case .destination(let d): return d.name
            case .builtIn(let id): return id.displayLabel
            }
        }

        var next: [ChainStep] {
            switch self {
            case .shortcut(let s): return s.next
            case .destination(let d): return d.next
            case .builtIn: return []  // built-ins are leaf transforms
            }
        }
    }

    // MARK: - Public entry

    /// Runs a chain. Use this when an action that's been triggered has a
    /// non-empty `next:` list.
    ///
    /// Pulses the menu bar icon for the chain duration (via
    /// `BackgroundTaskTracker.shared`). Surfaces a toast on completion.
    ///
    /// - Parameters:
    ///   - steps: ordered list of `ChainStep` values to run.
    ///   - initialInput: the starting pipe value (typically the user's
    ///     clipboard at chain start).
    ///   - sourceBundleId: bundle ID of the app the user copied from; forwarded
    ///     to `|llm` filters, inline LLM steps, and Context Snippet lookups.
    ///   - runInBackground: the originating action's own flag. Chains always
    ///     dismiss the panel at trigger, so this is NOT "are we on the
    ///     background path" (we always are) — it's whether the user asked this
    ///     action to stay out of the way, which outranks a "Show in Cai"
    ///     terminator. See `ResultRouting.route`.
    func runChain(
        _ steps: [ChainStep],
        initialInput: String,
        sourceBundleId: String?,
        name: String? = nil,
        runInBackground: Bool = false
    ) async {
        // Drives the in-progress indicator (and, in lockstep, the menu-bar
        // blink). `name` is the originating action's title when the caller knows
        // it; nested runs keep the outermost name (see `ExecutionState.reduce`).
        // Falls back to the last step's label for standalone chain runs.
        ExecutionState.shared.start(name: name ?? steps.last?.displayLabel ?? "Running")
        defer { ExecutionState.shared.finish() }

        do {
            let (finalOutput, terminal) = try await execute(
                steps: steps,
                pipe: initialInput,
                sourceBundleId: sourceBundleId,
                visited: [],
                depth: 0
            )

            // The default sink: output no destination consumed is kept on the
            // run's completion record instead of being dropped once the toast
            // snippet is built (finding #18).
            let routing = ResultRouting.route(
                text: finalOutput, terminal: terminal, runInBackground: runInBackground
            )
            let runName = name ?? steps.last?.displayLabel ?? "Action"
            if routing == .record || routing == .showInPanel {
                ExecutionState.shared.reportResult(
                    ExecutionState.RunResult(actionName: runName, text: finalOutput)
                )
            }
            if routing == .showInPanel {
                // Foreground run with an explicit "Show in Cai" terminator —
                // the only path that opens the panel on its own, because it is
                // the only one where the chain asked for it.
                NotificationCenter.default.post(name: .caiShowRunResult, object: nil)
            }

            // Toast with a sanitized snippet (collapsed whitespace, capped at
            // 60 chars) so the user sees the chain produced something. The
            // toast pill is single-line AppKit, so internal newlines from
            // multi-line LLM output (e.g. markdown lists, bullets) blow out
            // the pill's layout — collapse them to spaces before showing.
            let snippet = singleLineSnippet(from: finalOutput, maxChars: 60)
            let lastStepLabel = steps.last?.displayLabel ?? "chain"
            let message = snippet.isEmpty
                ? "Done — \(lastStepLabel)"
                : snippet
            NotificationCenter.default.post(
                name: .caiShowToast,
                object: nil,
                userInfo: ["message": message]
            )
        } catch {
            // Mark the run failed so the progress view shows the error (the
            // `defer`red `finish()` commits it). The toast remains the signal
            // when the panel was dismissed.
            ExecutionState.shared.reportFailure(error.localizedDescription)
            NotificationCenter.default.post(
                name: .caiShowToast,
                object: nil,
                userInfo: ["message": "Chain failed: \(error.localizedDescription)"]
            )
        }
    }

    /// Collapses whitespace runs (including newlines and tabs) into single spaces,
    /// trims edges, and truncates to `maxChars` with a trailing `…` if the
    /// original was longer. Used for toast/snippet display where multi-line
    /// LLM output would otherwise blow out a single-line pill's layout.
    private func singleLineSnippet(from text: String, maxChars: Int) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > maxChars else { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }

    // MARK: - Recursive executor

    /// Executes the steps sequentially. Returns the final pipe value together
    /// with what the LAST step to actually run was, which the default sink
    /// needs in order to tell "a destination took this" from "nobody took this".
    ///
    /// The terminal kind cannot be read off `steps.last`: this function recurses
    /// depth-first into a resolved action's own `next:` AFTER running it, so a
    /// chain `[Summarize, Notes]` where Notes carries `next: [Translate]` ends
    /// on an LLM step even though the top-level list ends on a destination.
    /// Reading the array would report that translation as consumed and drop it —
    /// exactly the bug this whole change exists to fix.
    /// Each `.action`-typed step also runs ITS OWN `next:` chain before
    /// moving on, so a chain of [A→B] where A also has `next: [Z]` produces
    /// A → Z → B (depth-first). Inline LLM and Apple Shortcut steps don't
    /// have their own `next:` (they're leaf step types).
    ///
    /// Cycle detection only applies to `.action` steps, since only named
    /// actions can recurse via their own `next:`. Inline LLM directives and
    /// Apple Shortcuts can't reference back into a Cai chain by name, so
    /// they can't form cycles structurally.
    private func execute(
        steps: [ChainStep],
        pipe: String,
        sourceBundleId: String?,
        visited: Set<String>,
        depth: Int
    ) async throws -> (output: String, terminal: ResultRouting.TerminalStep) {
        var currentPipe = pipe
        var currentVisited = visited
        // An empty step list changes nothing, so the pipe it hands back is just
        // its input — treat that as plain text rather than a consumed one.
        var terminal: ResultRouting.TerminalStep = .producesText

        for (stepIndex, step) in steps.enumerated() {
            if depth >= Self.maxDepth {
                throw ChainError.tooDeep(maxDepth: Self.maxDepth)
            }

            // Surface top-level step progress to the in-progress indicator.
            // Only depth 0 counts toward "Step N of M" — nested `next:` chains
            // would make the denominator meaningless.
            if depth == 0 {
                ExecutionState.shared.advance(
                    index: stepIndex + 1, total: steps.count, label: step.displayLabel
                )
            }

            // Cycle check applies only to named actions (the recursive case).
            if case .action(let name) = step {
                if currentVisited.contains(name) {
                    throw ChainError.cycle(detected: name, path: Array(currentVisited))
                }
                currentVisited.insert(name)
            }

            // Dispatch the step.
            let stepOutput: String
            do {
                (stepOutput, terminal) = try await runStep(
                    step,
                    input: currentPipe,
                    sourceBundleId: sourceBundleId
                )
            } catch let chainError as ChainError {
                // Don't double-wrap structural chain errors (unknownAction,
                // invalidStep, etc.) — they're already self-describing.
                // Only execution failures (NSError from a shell command, an
                // LLM timeout, etc.) get wrapped with the step name context.
                throw chainError
            } catch {
                throw ChainError.stepFailed(action: step.displayLabel, underlying: error)
            }

            currentPipe = stepOutput

            // Recurse into the action's own `next:` (only `.action` steps
            // have one; inline LLM and Apple Shortcut steps are leaves).
            if case .action(let name) = step,
               let resolved = resolve(name),
               !resolved.next.isEmpty {
                // The nested chain ran after this step, so ITS terminal is the
                // one that counts.
                (currentPipe, terminal) = try await execute(
                    steps: resolved.next,
                    pipe: currentPipe,
                    sourceBundleId: sourceBundleId,
                    visited: currentVisited,
                    depth: depth + 1
                )
            }
        }

        return (currentPipe, terminal)
    }

    // MARK: - Lookup

    private func resolve(_ name: String) -> ResolvedAction? {
        if let injected = injectedResolver {
            return injected(name)
        }
        // Resolution order (user customizations win):
        //   1. User-defined shortcuts
        //   2. User + built-in destinations (both live in `outputDestinations`)
        //   3. Built-in chainable actions
        // A user shortcut named "Translate" intentionally beats the built-in
        // Translate — same precedence as the action-list dispatch.
        if let shortcut = CaiSettings.shared.shortcuts.first(where: { $0.name == name }) {
            return .shortcut(shortcut)
        }
        if let dest = CaiSettings.shared.outputDestinations.first(where: { $0.name == name }) {
            return .destination(dest)
        }
        if let builtIn = BuiltInActionID.allCases.first(where: {
            $0.isChainable && $0.displayLabel == name
        }) {
            return .builtIn(builtIn)
        }
        return nil
    }

    // MARK: - Test entry
    //
    // Exposes the throwing recursive executor so tests can assert directly on
    // outputs and `ChainError` cases. The public `runChain(...)` wraps this
    // with toast + tracker plumbing, both of which are tedious to test.

    #if DEBUG
    func executeForTesting(
        steps: [ChainStep],
        initialInput: String,
        sourceBundleId: String? = nil
    ) async throws -> String {
        try await execute(
            steps: steps,
            pipe: initialInput,
            sourceBundleId: sourceBundleId,
            visited: [],
            depth: 0
        ).output
    }

    /// Same as `executeForTesting` but also returns the step that actually ran
    /// last — what the default sink routes on. Separate entry point so the
    /// existing chain tests keep their simpler signature.
    func executeTerminalForTesting(
        steps: [ChainStep],
        initialInput: String,
        sourceBundleId: String? = nil
    ) async throws -> (output: String, terminal: ResultRouting.TerminalStep) {
        try await execute(
            steps: steps,
            pipe: initialInput,
            sourceBundleId: sourceBundleId,
            visited: [],
            depth: 0
        )
    }
    #endif

    // MARK: - Single-step dispatch

    private func runStep(
        _ step: ChainStep,
        input: String,
        sourceBundleId: String?
    ) async throws -> (String, ResultRouting.TerminalStep) {
        switch step {
        case .action(let name):
            guard let resolved = resolve(name) else {
                throw ChainError.unknownAction(name)
            }
            return try await runAction(resolved, input: input, sourceBundleId: sourceBundleId)

        case .inlineLLM(let directive):
            // Empty directives shouldn't reach here — the editor strips them
            // on commit (see `ChainStepsEditor`). If one slips through (e.g.,
            // hand-edited storage), throw an error rather than silently
            // calling the LLM with no instruction (which produces garbage).
            let trimmed = directive.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ChainError.invalidStep("Inline LLM step has no directive")
            }
            let output = try await runInlineLLM(
                directive: trimmed, input: input, sourceBundleId: sourceBundleId
            )
            return (output, .producesText)

        case .appleShortcut(let name):
            return (try await runAppleShortcut(name: name, input: input), .producesText)
        }
    }

    private func runAction(
        _ action: ResolvedAction,
        input: String,
        sourceBundleId: String?
    ) async throws -> (String, ResultRouting.TerminalStep) {
        switch action {
        case .shortcut(let s):
            switch s.type {
            case .shell:
                let output = try await runShell(
                    template: s.value, input: input, sourceBundleId: sourceBundleId
                )
                return (output, .producesText)
            case .prompt:
                let output = try await runPrompt(
                    prompt: s.value, input: input, sourceBundleId: sourceBundleId
                )
                return (output, .producesText)
            case .url:
                let resolved = try await TemplateEngine.render(
                    s.value.replacingOccurrences(of: "%s", with: "{{result|url_encode|raw}}"),
                    vars: ["result": input],
                    context: .raw,
                    sourceBundleId: sourceBundleId
                )
                if let url = URL(string: resolved) {
                    NSWorkspace.shared.open(url)
                }
                // URL actions don't propagate output; the empty pipe routes to
                // `.nothing`, so no blank result surface.
                return ("", .producesText)
            }
        case .destination(let d):
            // OutputDestinationService is an actor; it handles its own threading.
            try await OutputDestinationService.shared.execute(d, with: input, sourceBundleId: sourceBundleId)
            // Pass through unchanged — destinations are `tee`-style: they
            // side-effect on the input, but the pipe keeps flowing so a
            // subsequent step (typically another destination) gets the same
            // content. See the doc comment at the top of the file.
            //
            // "Show in Cai" is the one destination that consumes nothing: it
            // exists to say "put this on screen", so it reports itself as such
            // and the default sink takes over.
            return (input, d.type == .showInCai ? .showInCai : .consumingDestination)
        case .builtIn(let id):
            let output = try await runBuiltIn(id, input: input, sourceBundleId: sourceBundleId)
            return (output, .producesText)
        }
    }

    // MARK: - Built-in action step
    //
    // Dispatches built-in LLM actions (Summarize, Explain, Reply, Fix Grammar,
    // Translate) using their tuned prompts from `LLMService.prompts(for:)`.
    // Same wrapping as `runPrompt` and `runInlineLLM` — About You + Context
    // Snippet via `buildMessages` — so behavior is consistent across all
    // chain step types.

    private func runBuiltIn(
        _ id: BuiltInActionID,
        input: String,
        sourceBundleId: String?
    ) async throws -> String {
        let llmAction = await MainActor.run { id.toLLMAction() }
        guard let llmAction else {
            // Defensive: resolve() filtered to isChainable, so this is a code
            // bug rather than a user-facing one. Surface it clearly.
            throw ChainError.invalidStep("Built-in action '\(id.displayLabel)' is not chainable")
        }
        let prompts = LLMService.prompts(for: llmAction, text: input, appContext: nil)
        let aboutYou = await MainActor.run { CaiSettings.shared.aboutYou }
        let snippet = ContextSnippetsManager.shared.snippet(forBundleId: sourceBundleId)

        let messages = LLMService.buildMessages(
            systemPrompt: prompts.system,
            userPrompt: prompts.user,
            aboutYou: aboutYou,
            snippet: snippet
        )

        let response = try await LLMService.shared.generateWithMessages(messages)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Inline LLM step
    //
    // A directive is treated as the "user prompt" for one-shot LLM call. The
    // chain pipe value is the "context" being transformed. Builds messages
    // via `LLMService.buildMessages` so About You + per-app Context Snippets
    // are injected the same way prompt-type shortcuts get them.

    private func runInlineLLM(
        directive: String,
        input: String,
        sourceBundleId: String?
    ) async throws -> String {
        let aboutYou = CaiSettings.shared.aboutYou
        let snippet = ContextSnippetsManager.shared.snippet(forBundleId: sourceBundleId)

        // System prompt frames the LLM to "do the directive on the input,
        // emit only the result". Same shape as `runPrompt` so chain-composed
        // and saved-prompt-type behave consistently.
        let systemPrompt = """
            You are a text transformation step in a pipeline. Apply the user's \
            directive to the input text and output ONLY the transformed result. \
            No preamble, no explanations, no quotes around the output. Plain \
            text, no markdown.

            Directive: \(directive)
            """

        let messages = LLMService.buildMessages(
            systemPrompt: systemPrompt,
            userPrompt: input,
            aboutYou: aboutYou,
            snippet: snippet
        )

        let response = try await LLMService.shared.generateWithMessages(messages)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Apple Shortcut step
    //
    // Spawns `/usr/bin/shortcuts run "Name"` with the chain pipe value as
    // stdin. Apple Shortcuts that include a "Receive Input from Quick
    // Action" step consume the stdin; ones that don't silently ignore it.
    // Stdout flows back into the chain pipe.
    //
    // 30s timeout (shorter than shell's 60s) — Shortcuts that need longer
    // are typically network-bound and the user is better served by chaining
    // via a shell action with an explicit timeout. Documented as a known
    // limitation in `_docs/integrations/APPLE-SHORTCUTS.md`.

    private func runAppleShortcut(name: String, input: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]

        let inputPipe = Pipe()
        inputPipe.fileHandleForWriting.write(input.data(using: .utf8) ?? Data())
        inputPipe.fileHandleForWriting.closeFile()
        process.standardInput = inputPipe

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let exitTask = Task.detached { process.waitUntilExit() }
        let timeoutTask = Task.detached {
            try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            process.terminate()
        }
        await exitTask.value
        timeoutTask.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw NSError(domain: "Cai", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Apple Shortcut '\(name)' exceeded 30s and was stopped"
            ])
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            // `shortcuts run` writes its errors to stderr (e.g. "No shortcut
            // found with name 'Foo'"). Surface that verbatim — the user
            // typically just typo'd the name.
            let message = stderr.isEmpty
                ? "Apple Shortcut '\(name)' failed (exit \(process.terminationStatus))"
                : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "Cai",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shell shortcut runner

    private func runShell(template: String, input: String, sourceBundleId: String?) async throws -> String {
        // Secrets travel in the environment, never in the command line.
        let secrets = try SecretStore.prepareForShell(template: template)
        let resolved = try await TemplateEngine.render(
            template,
            vars: ["result": input],
            context: .shell,
            sourceBundleId: sourceBundleId,
            secrets: secrets.access
        )

        // Stdin = pipe value (so users can `cat`-style consume it in their command).
        let output = try await ShellRunner.run(resolved, stdin: input, environment: secrets.environment)

        if output.timedOut {
            throw ShellRunner.timeoutError()
        }

        guard output.status == 0 else {
            throw NSError(domain: "Cai", code: Int(output.status), userInfo: [
                NSLocalizedDescriptionKey: Redactor.redact(output.failureMessage, using: secrets.values)
            ])
        }

        // A command can print its own environment, and this value continues down
        // the chain into other actions and the user's clipboard.
        return Redactor.redact(output.trimmedStdout, using: secrets.values)
    }

    // MARK: - Prompt shortcut runner
    //
    // Builds messages via `LLMService.buildMessages` (which handles "About You"
    // and Context Snippet injection) and dispatches via `generateWithMessages`.

    private func runPrompt(prompt: String, input: String, sourceBundleId: String?) async throws -> String {
        // Substitute {{result}} in the prompt with the pipe value, plus any
        // standard variables the engine knows about. Context.raw means no
        // automatic escaping — the prompt is sent verbatim to the LLM.
        let userPrompt = try await TemplateEngine.render(
            prompt,
            vars: ["result": input],
            context: .raw,
            sourceBundleId: sourceBundleId
        )

        let aboutYou = CaiSettings.shared.aboutYou
        let snippet = ContextSnippetsManager.shared.snippet(forBundleId: sourceBundleId)

        // System prompt frames the LLM for "output the result, no preamble"
        // so chain steps can compose cleanly. User-defined prompts sometimes
        // bury the actual ask in conversational context; this keeps output tight.
        let systemPrompt = """
            Output ONLY the result. No preamble, no explanations, no quotes around \
            the output. Plain text, no markdown.
            """

        let messages = LLMService.buildMessages(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            aboutYou: aboutYou,
            snippet: snippet
        )

        let response = try await LLMService.shared.generateWithMessages(messages)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
