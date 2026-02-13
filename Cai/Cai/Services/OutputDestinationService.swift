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
        case .urlScheme(let template):
            try await executeURLScheme(template, text: text, fields: destination.setupFields)
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

        try await MainActor.run {
            var errorDict: NSDictionary?
            guard let script = NSAppleScript(source: resolved) else {
                throw OutputDestinationError.appleScriptFailed("Failed to create script")
            }
            script.executeAndReturnError(&errorDict)
            if let error = errorDict {
                let message = error[NSAppleScript.errorMessage] as? String ?? error.description
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

        print("🌐 Webhook URL: \(resolvedURL)")
        print("🌐 Webhook body: \(resolvedBody.prefix(500))")

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
        print("🌐 Webhook response: \(http.statusCode) — \(responseBody.prefix(300))")

        guard (200...299).contains(http.statusCode) else {
            throw OutputDestinationError.webhookFailed(http.statusCode, responseBody)
        }
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

    // MARK: - URL Scheme

    private func executeURLScheme(_ template: String, text: String, fields: [SetupField]) async throws {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let resolved = resolveTemplate(template, text: encoded, fields: fields)

        guard let url = URL(string: resolved) else {
            throw OutputDestinationError.invalidURL
        }

        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Shell Command

    private func executeShell(_ command: String, text: String, fields: [SetupField]) async throws {
        let resolved = resolveTemplate(command, text: text, fields: fields)

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

        // Timeout after 15 seconds
        let deadline = DispatchTime.now() + .seconds(15)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }

        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw OutputDestinationError.timeout
        }

        guard process.terminationStatus == 0 else {
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw OutputDestinationError.shellFailed(Int(process.terminationStatus), output)
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
