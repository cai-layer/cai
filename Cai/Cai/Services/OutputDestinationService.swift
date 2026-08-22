import Cocoa

/// Executes output destinations — sends text to external apps and services.
/// Actor-isolated for thread safety (same pattern as LLMService).
actor OutputDestinationService {
    static let shared = OutputDestinationService()

    private init() {}

    // MARK: - Execute

    /// Sends text to the given destination, resolving all template placeholders.
    ///
    /// `sourceBundleId` is required for `.pasteBack`: it identifies the app to
    /// re-activate before pasting. Other destination types ignore it.
    func execute(_ destination: OutputDestination, with text: String, sourceBundleId: String? = nil) async throws {
        // Verify all setup fields are configured
        for field in destination.setupFields where field.value.isEmpty {
            throw OutputDestinationError.notConfigured(field.key)
        }

        switch destination.type {
        case .applescript(let template):
            try await executeAppleScript(template, text: text, fields: destination.setupFields, sourceBundleId: sourceBundleId)
        case .webhook(let config):
            try await executeWebhook(config, text: text, fields: destination.setupFields, sourceBundleId: sourceBundleId)
        case .deeplink(let template):
            try await executeDeeplink(template, text: text, fields: destination.setupFields, sourceBundleId: sourceBundleId)
        case .shell(let command):
            try await executeShell(command, text: text, fields: destination.setupFields, sourceBundleId: sourceBundleId)
        case .pasteBack:
            try await executePasteBack(text: text, sourceBundleId: sourceBundleId)
        case .clipboardCopy:
            // Route through PasteboardQueue so the write serializes with every
            // other pasteboard op (no concurrent access with reads/paste-back).
            PasteboardQueue.shared.write {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case .showInCai:
            // Deliberately nothing. This destination's whole job is to NOT
            // consume the pipe, so the default sink surfaces it — the routing
            // decision lives in `ResultRouting.route`, keyed on this being the
            // terminal step. A side-effect here would be the bug.
            break
        }
    }

    // MARK: - Paste Back

    private func executePasteBack(text: String, sourceBundleId: String?) async throws {
        // Both `.pasted` and `.copiedForManualPaste` are user-successful outcomes
        // (text was either pasted or is on the clipboard ready for ⌘V). Only
        // `.failed` throws. Note: ActionListWindow special-cases pasteBack to
        // call ClipboardService directly so it can surface the three outcomes
        // as distinct toasts — this service path is kept for parity but loses
        // the outcome distinction by necessity (throws/doesn't).
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ClipboardService.PasteOutcome, Never>) in
            Task { @MainActor in
                ClipboardService.shared.pasteResult(text, toBundleId: sourceBundleId) { outcome in
                    continuation.resume(returning: outcome)
                }
            }
        }
        if case .failed = outcome {
            throw OutputDestinationError.pasteBackFailed
        }
    }

    // MARK: - AppleScript

    private func executeAppleScript(_ template: String, text: String, fields: [SetupField], sourceBundleId: String?) async throws {
        // If the template targets Notes.app (body property), convert to simple HTML
        // so line breaks and basic formatting survive.
        // AppleScript escaping is handled at the call site (engine has no
        // dedicated AppleScript context — see SHELL-TODOS.md "Updates 2026-05-03").
        let processedText: String
        if template.contains("application \"Notes\"") && template.contains("body:") {
            processedText = escapeForAppleScript(plainTextToHTML(text))
        } else {
            processedText = escapeForAppleScript(text)
        }
        let resolved = try await render(
            template, text: processedText, fields: fields,
            context: .raw, sourceBundleId: sourceBundleId
        )

        let targetApp = Self.extractTargetApp(from: template)

        try await MainActor.run {
            var errorDict: NSDictionary?
            guard let script = NSAppleScript(source: resolved) else {
                throw OutputDestinationError.appleScriptFailed("Failed to create script")
            }
            script.executeAndReturnError(&errorDict)
            if let error = errorDict {
                let message = error[NSAppleScript.errorMessage] as? String ?? error.description
                let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
                // -1743 = "not allowed" (Automation permission denied)
                // -1002 = "not permitted to send Apple events"
                if errorNumber == -1743 || errorNumber == -1002 || message.lowercased().contains("not allowed") {
                    Self.showAutomationPermissionAlert(for: targetApp)
                    throw OutputDestinationError.appleScriptFailed("Permission denied for \(targetApp ?? "this app").")
                }
                throw OutputDestinationError.appleScriptFailed(message)
            }
        }
    }

    /// Converts plain text to simple HTML for apps that expect it (e.g. Notes.app).
    /// Preserves line breaks and escapes HTML entities.
    private func plainTextToHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    /// Escapes text for safe insertion into AppleScript string literals.
    /// Handles backslashes, quotes, and newlines.
    private func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Webhook

    private func executeWebhook(_ config: WebhookConfig, text: String, fields: [SetupField], sourceBundleId: String?) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // URL substitutes setup-field placeholders ({{slack_webhook_url}} etc.) raw —
        // the URL is constructed verbatim from user-supplied components.
        let resolvedURL = try await render(
            config.url, text: trimmedText, fields: fields,
            context: .raw, sourceBundleId: sourceBundleId
        )
        // Collapse body template to single line (TextEditor may introduce line breaks)
        let compactBody = config.bodyTemplate
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
        // .json context applies |json by default to bare {{result}} so the body is
        // valid JSON for any clipboard content (quotes, newlines, unicode all escaped).
        let resolvedBody = try await render(
            compactBody, text: trimmedText, fields: fields,
            context: .json, sourceBundleId: sourceBundleId
        )

        #if DEBUG
        // Log host + length only — resolved URL can carry query-param secrets,
        // and the body contains clipboard + LLM output after template resolution.
        let webhookHost = URL(string: resolvedURL)?.host ?? "unknown"
        print("🌐 Webhook → \(webhookHost), body: \(resolvedBody.count) chars")
        #endif

        guard let url = URL(string: resolvedURL) else {
            throw OutputDestinationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = config.method
        request.httpBody = resolvedBody.data(using: .utf8)
        request.timeoutInterval = 15

        for (key, value) in config.headers {
            // Headers are raw — no automatic escaping. Setup fields like {{api_key}}
            // are substituted verbatim (matches v1 behavior).
            let resolvedValue = try await render(
                value, text: trimmedText, fields: fields,
                context: .raw, sourceBundleId: sourceBundleId
            )
            request.setValue(resolvedValue, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OutputDestinationError.webhookFailed(0, "Invalid response")
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""
        #if DEBUG
        // Log status + length only — webhook servers sometimes echo clipboard
        // content, request bodies, or user identifiers back in responses.
        print("🌐 Webhook response: \(http.statusCode) (\(responseBody.count) chars)")
        #endif

        guard (200...299).contains(http.statusCode) else {
            throw OutputDestinationError.webhookFailed(http.statusCode, responseBody)
        }
    }

    // Note: `escapeForShell` and `escapeForJSON` (formerly inline here) were removed
    // when this service was wired through `TemplateEngine`. The engine's `Context.shell`
    // and `Context.json` defaults apply the canonical `|shell` and `|json` filters,
    // which encapsulate the same escaping logic in one place. See SHELL-TODOS.md.

    // MARK: - Deeplink

    private func executeDeeplink(_ template: String, text: String, fields: [SetupField], sourceBundleId: String?) async throws {
        // .url context applies |url_encode by default to bare {{result}} using the
        // RFC 3986 unreserved character set — stricter than the v1 .urlQueryAllowed
        // pre-escape, so `&` and `=` in clipboard text now get encoded too. This is
        // a strict safety improvement: clipboard with `&` no longer breaks the
        // surrounding URL into separate query parameters.
        let resolved = try await render(
            template, text: text, fields: fields,
            context: .url, sourceBundleId: sourceBundleId
        )

        guard let url = URL(string: resolved) else {
            throw OutputDestinationError.invalidURL
        }

        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Shell Command

    private func executeShell(_ command: String, text: String, fields: [SetupField], sourceBundleId: String?) async throws {
        // .shell context applies |shell by default to bare {{result}} (single-quote
        // wrap + escape). Same output as the v1 escapeForShell pre-escape produced.
        // Secrets travel in the environment, never in the command line.
        let secrets = try SecretStore.prepareForShell(template: command)
        let resolved = try await render(
            command, text: text, fields: fields,
            context: .shell, sourceBundleId: sourceBundleId,
            secrets: secrets.access
        )

        // stderr is merged into stdout here, unlike the action paths: a failing
        // destination reports one combined stream to the user.
        let output = try await ShellRunner.run(
            resolved,
            stdin: text,
            environment: secrets.environment,
            mergeStderrIntoStdout: true
        )

        if output.timedOut {
            throw OutputDestinationError.timeout
        }

        guard output.status == 0 else {
            throw OutputDestinationError.shellFailed(
                Int(output.status),
                Redactor.redact(output.stdout, using: secrets.values)
            )
        }
    }

    // MARK: - Automation Permission

    /// Extracts the target app name from an AppleScript template (e.g. "Notes" from `tell application "Notes"`).
    private static func extractTargetApp(from template: String) -> String? {
        let pattern = #"tell application \"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: template, range: NSRange(template.startIndex..., in: template)),
              let range = Range(match.range(at: 1), in: template) else {
            return nil
        }
        return String(template[range])
    }

    /// Purpose descriptions for built-in apps — shown in the permission alert.
    private static let appPurposeDescriptions: [String: String] = [
        "Notes": "to create a new note from Cai results",
        "Mail": "to draft an email from Cai results",
        "Reminders": "to create reminders from Cai results"
    ]

    /// Shows an NSAlert explaining why Automation permission is needed, with a button to open System Settings.
    @MainActor
    private static func showAutomationPermissionAlert(for appName: String?) {
        let app = appName ?? "this app"
        let purpose = appName.flatMap { appPurposeDescriptions[$0] } ?? "to send content from Cai"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cai needs permission to control \(app)"
        alert.informativeText = "Cai requires Automation access to \(app) \(purpose).\n\nGo to System Settings → Privacy & Security → Automation and enable \(app) under Cai."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        // Force the alert to the front (Cai is an LSUIElement app)
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Deep-link to Automation pane in System Settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Template Resolution

    /// Renders a template via the shared `TemplateEngine`, building the variable
    /// map from clipboard text + the destination's setup fields. The `context`
    /// controls which default filter applies to bare `{{result}}` (e.g. `.shell`
    /// adds the `|shell` wrap+escape; `.json` adds JSON escaping; `.url` adds
    /// percent-encoding; `.raw` does no automatic escaping). `sourceBundleId`
    /// is forwarded so any `|llm` filters in the template inherit the per-app
    /// Context Snippet, matching the UX of regular Prompt actions.
    private func render(
        _ template: String,
        text: String,
        fields: [SetupField],
        context: TemplateEngine.Context,
        sourceBundleId: String?,
        secrets: TemplateEngine.SecretAccess? = nil
    ) async throws -> String {
        var vars: [String: String] = ["result": text]
        for field in fields {
            vars[field.key] = field.value
        }
        // Defaults to nil, so every destination surface except shell refuses
        // secrets until it is deliberately opted in. Webhook headers and bodies
        // are the next ones to enable.
        return try await TemplateEngine.render(
            template,
            vars: vars,
            context: context,
            sourceBundleId: sourceBundleId,
            secrets: secrets
        )
    }

    /// Environment for `/bin/zsh -c` subprocesses. Non-interactive zsh doesn't
    /// source `.zshrc`, so Homebrew bin dirs are off PATH by default — every
    /// shell shortcut/destination that calls `gh`, `jq`, `kubectl`, etc. fails
    /// with "command not found" until the user hardcodes an absolute path.
    /// Prepending the standard Homebrew paths fixes the 90% case without
    /// pulling in the user's full dotfile state (which would be slow and
    /// non-deterministic). Tools managed by nvm/pyenv/conda still need
    /// absolute paths or wrappers.
    static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(extraPaths):\(currentPath)"
        return env
    }
}
