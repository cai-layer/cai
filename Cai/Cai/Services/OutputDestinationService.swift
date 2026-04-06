import Cocoa

/// Executes output destinations — sends text to external apps and services.
/// Actor-isolated for thread safety (same pattern as LLMService).
actor OutputDestinationService {
    static let shared = OutputDestinationService()

    private init() {}

    // MARK: - Execute

    /// Sends text to the given destination, resolving all template placeholders.
    func execute(_ destination: OutputDestination, with text: String) async throws {
        // Verify all setup fields are configured
        for field in destination.setupFields where field.value.isEmpty {
            throw OutputDestinationError.notConfigured(field.key)
        }

        switch destination.type {
        case .applescript(let template):
            try await executeAppleScript(template, text: text, fields: destination.setupFields)
        case .webhook(let config):
            try await executeWebhook(config, text: text, fields: destination.setupFields)
        case .deeplink(let template):
            try await executeDeeplink(template, text: text, fields: destination.setupFields)
        case .shell(let command):
            try await executeShell(command, text: text, fields: destination.setupFields)
        }
    }

    // MARK: - AppleScript

    private func executeAppleScript(_ template: String, text: String, fields: [SetupField]) async throws {
        // If the template targets Notes.app (body property), convert to simple HTML
        // so line breaks and basic formatting survive.
        let processedText: String
        if template.contains("application \"Notes\"") && template.contains("body:") {
            processedText = escapeForAppleScript(plainTextToHTML(text))
        } else {
            processedText = escapeForAppleScript(text)
        }
        let resolved = resolveTemplate(template, text: processedText, fields: fields)

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

    private func executeWebhook(_ config: WebhookConfig, text: String, fields: [SetupField]) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = resolveTemplate(config.url, text: trimmedText, fields: fields)
        // Collapse body template to single line (TextEditor may introduce line breaks)
        let compactBody = config.bodyTemplate
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
        let resolvedBody = resolveTemplate(compactBody, text: escapeForJSON(trimmedText), fields: fields)

        #if DEBUG
        print("🌐 Webhook URL: \(resolvedURL)")
        print("🌐 Webhook body: \(resolvedBody.prefix(500))")
        #endif

        guard let url = URL(string: resolvedURL) else {
            throw OutputDestinationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = config.method
        request.httpBody = resolvedBody.data(using: .utf8)
        request.timeoutInterval = 15

        for (key, value) in config.headers {
            let resolvedValue = resolveTemplate(value, text: trimmedText, fields: fields)
            request.setValue(resolvedValue, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OutputDestinationError.webhookFailed(0, "Invalid response")
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""
        #if DEBUG
        print("🌐 Webhook response: \(http.statusCode) — \(responseBody.prefix(300))")
        #endif

        guard (200...299).contains(http.statusCode) else {
            throw OutputDestinationError.webhookFailed(http.statusCode, responseBody)
        }
    }

    /// Escapes text for safe embedding in shell commands via single-quote wrapping.
    /// Prevents injection when clipboard text is substituted into {{result}}.
    private func escapeForShell(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes text for safe embedding inside a JSON string value.
    /// Uses JSONEncoder so every special character (newlines, quotes, unicode,
    /// control chars) is handled correctly — works even when the JSON string
    /// is nested inside another string (e.g. GraphQL query inside JSON body).
    private func escapeForJSON(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text),
              let jsonString = String(data: data, encoding: .utf8) else {
            // Fallback: manual escaping if encoder somehow fails
            return text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
        }
        // JSONEncoder wraps in quotes: "hello" → strip the outer quotes
        return String(jsonString.dropFirst().dropLast())
    }

    // MARK: - Deeplink

    private func executeDeeplink(_ template: String, text: String, fields: [SetupField]) async throws {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let resolved = resolveTemplate(template, text: encoded, fields: fields)

        guard let url = URL(string: resolved) else {
            throw OutputDestinationError.invalidURL
        }

        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Shell Command

    private func executeShell(_ command: String, text: String, fields: [SetupField]) async throws {
        let resolved = resolveTemplate(command, text: escapeForShell(text), fields: fields)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", resolved]

        // Pass text as stdin
        let inputPipe = Pipe()
        let inputData = text.data(using: .utf8) ?? Data()
        inputPipe.fileHandleForWriting.write(inputData)
        inputPipe.fileHandleForWriting.closeFile()
        process.standardInput = inputPipe

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()

        // Timeout after 15 seconds — race process exit against a sleep.
        // Using Task instead of DispatchSemaphore.wait keeps us async-safe
        // (Swift 6 requires this; DispatchSemaphore.wait is unavailable from async contexts).
        let exitTask = Task.detached {
            process.waitUntilExit()
        }
        let timeoutTask = Task.detached {
            try await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            process.terminate()
        }
        await exitTask.value
        timeoutTask.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw OutputDestinationError.timeout
        }

        guard process.terminationStatus == 0 else {
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw OutputDestinationError.shellFailed(Int(process.terminationStatus), output)
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

    /// Replaces {{result}} and {{field_key}} placeholders in a template string.
    private func resolveTemplate(_ template: String, text: String, fields: [SetupField]) -> String {
        var result = template.replacingOccurrences(of: "{{result}}", with: text)
        for field in fields {
            result = result.replacingOccurrences(of: "{{\(field.key)}}", with: field.value)
        }
        return result
    }
}
