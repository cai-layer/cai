import Foundation

/// Rebuilds the Today list by running the user's own `claude` headless with
/// the `cai-today` skill, from the Today folder.
///
/// - `claude` is started through `ShellRunner.launch` with an argument array,
///   never through a shell, with stdin on `/dev/null`.
/// - The run is read-only by tool rules: `allowedTools` is the whole list of
///   tools it may use, and a headless run refuses every tool not on it.
///   Hooks are off. File edits are accepted only in the working folder,
///   `Today/`, which holds only the skill's files; Cai's own files are in
///   `TodayState/` (see `TodayStore`).
/// - The skill rewrites `items.jsonl`; `TodayStore`'s watcher reloads it, so
///   nothing here reads items.
/// - One run at a time. It belongs to this singleton, not to the view, so it
///   finishes when the panel closes.
/// - `TodayState/runs.log` gets one line per run: when, how long, cost, turns and the
///   tool calls that were refused. No item text and no prompt text.
@MainActor
final class TodayRunner: ObservableObject {
    static let shared = TodayRunner()

    enum Phase: Equatable {
        case idle
        case running(started: Date)
        case failed(reason: String)
    }

    /// A tool source from the run's `system/init` event. Setup and Settings
    /// show these in a later PR.
    struct Connector: Equatable {
        let name: String
        let status: String
    }

    /// The fields Cai keeps from the run's final `result` event.
    struct RunResult: Equatable {
        var durationMs: Int?
        var costUSD: Double?
        var turns: Int?
        var isError: Bool
        /// Why the run failed, for the header tooltip. Never logged.
        var errorText: String?
        /// Refused tool calls, as `runs.log` records them.
        var denied: [String]
    }

    enum Event: Equatable {
        case initialized([Connector])
        case finished(RunResult)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastRunSeconds: Int?
    @Published private(set) var connectors: [Connector] = []
    /// Nil until looked up, then whether `claude` was found.
    @Published private(set) var claudeFound: Bool?

    private var claudePath: String?
    private var loginPath: String?
    private var lookingUp = false
    private var lastStarted: Date?

    /// A full run took about 2 minutes in dogfood; 20 leaves room for a slow
    /// connector without letting a stuck run go on for hours.
    nonisolated static let timeout: TimeInterval = 20 * 60
    /// After SIGINT Claude Code ends the turn and writes its result event.
    nonisolated static let interruptGrace: TimeInterval = 30
    nonisolated static let staleAfter: TimeInterval = 2 * 60 * 60

    static var skillFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/cai-today")
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    // MARK: - Triggers

    /// ⌘R, or ↵ on the empty state. Does nothing while a run is going.
    func start() {
        guard !isRunning else { return }
        let started = Date()
        lastStarted = started
        phase = .running(started: started)
        Task { await run(started: started) }
    }

    /// Opening Today: refresh in the background when the list is old.
    func refreshIfStale(generated: Date?) {
        if Self.shouldRefreshOnOpen(generated: generated, lastStarted: lastStarted, running: isRunning, now: Date()) {
            start()
        }
    }

    /// Finds `claude` once, so the empty state knows whether ↵ can build.
    func lookUpClaude() {
        guard claudeFound == nil, !lookingUp else { return }
        lookingUp = true
        Task {
            _ = await resolveClaude()
            lookingUp = false
        }
    }

    // MARK: - The run

    private func run(started: Date) async {
        guard FileManager.default.fileExists(atPath: Self.skillFolder.path) else {
            phase = .failed(reason: "Install the cai-today skill first")
            return
        }
        guard let claude = await resolveClaude() else {
            phase = .failed(reason: "Claude Code isn't installed")
            return
        }
        let folder = TodayStore.folder
        TodayStore.prepareFolders()

        let collector = StreamCollector()
        let output: ShellRunner.Output
        do {
            output = try await ShellRunner.launch(
                URL(fileURLWithPath: claude),
                arguments: Self.arguments(priorities: TodayStore.prioritiesURL),
                stdin: nil,
                environment: Self.environment(base: ProcessInfo.processInfo.environment, loginPath: loginPath),
                currentDirectory: folder,
                timeout: Self.timeout,
                interrupt: SIGINT,
                killGrace: Self.interruptGrace,
                outputCap: 64 * 1024,
                onStdout: collector.append,
                killDescendants: true
            )
        } catch {
            phase = .failed(reason: "Claude Code couldn't start")
            return
        }

        let (initialized, result) = collector.finish()
        if let initialized { connectors = initialized }
        let wall = Date().timeIntervalSince(started)
        Self.append(Self.logLine(at: started, result: result, wallSeconds: wall), to: TodayStore.runsLogURL)
        lastRunSeconds = result?.durationMs.map { $0 / 1000 } ?? Int(wall)
        phase = Self.outcome(result: result, status: output.status, timedOut: output.timedOut, stderr: output.stderr)
    }

    private func resolveClaude() async -> String? {
        if let claudePath, FileManager.default.isExecutableFile(atPath: claudePath) { return claudePath }
        let path = await ShellEnvCapture.loginPath()
        loginPath = path
        let fallback = OutputDestinationService.shellEnvironment()["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // ~/.local/bin is where Claude Code's own installer puts `claude`,
        // which is not on PATH when a shell only aliases it.
        let found = Self.resolve("claude", searchPath: [path ?? "", fallback, "\(home)/.local/bin"].joined(separator: ":"))
        claudePath = found
        claudeFound = found != nil
        return found
    }

    private static func append(_ line: String, to url: URL) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Arguments (reviewed)

    /// Every tool the run may use. A headless run refuses anything else, so
    /// this list is the run's whole reach. Each entry must pass `isReadOnly`
    /// (`TodayRunnerTests`); widening it is a security review, not a tweak.
    /// Matches `dogfood-run.sh`, with the Pylon names read from a real run's
    /// init event. Linear is left out: it needs sign-in on this Mac first.
    nonisolated static let allowedTools: [String] = [
        // Files. Writes are limited to the working folder by acceptEdits; the
        // skill writes a .tmp file and renames it, and these two renames are
        // the only shell file operations allowed.
        "Read", "Glob", "Grep", "Skill",
        "Bash(mv items.jsonl.tmp items.jsonl)",
        "Bash(mv candidates.json.tmp candidates.json)",
        "Bash(date:*)",
        // GitHub, read subcommands only.
        "Bash(gh auth status)",
        "Bash(gh search:*)",
        "Bash(gh pr list:*)", "Bash(gh pr view:*)", "Bash(gh pr status:*)",
        "Bash(gh issue list:*)", "Bash(gh issue view:*)", "Bash(gh issue status:*)",
        // Slack
        "mcp__claude_ai_Slack__slack_search_public",
        "mcp__claude_ai_Slack__slack_search_public_and_private",
        "mcp__claude_ai_Slack__slack_search_channels",
        "mcp__claude_ai_Slack__slack_search_users",
        "mcp__claude_ai_Slack__slack_read_channel",
        "mcp__claude_ai_Slack__slack_read_thread",
        "mcp__claude_ai_Slack__slack_read_user_profile",
        "mcp__claude_ai_Slack__slack_list_user_channels",
        "mcp__claude_ai_Slack__slack_read_canvas",
        // Gmail
        "mcp__claude_ai_Gmail__search_threads",
        "mcp__claude_ai_Gmail__get_thread",
        "mcp__claude_ai_Gmail__get_message",
        "mcp__claude_ai_Gmail__list_labels",
        // Google Calendar
        "mcp__claude_ai_Google_Calendar__list_events",
        "mcp__claude_ai_Google_Calendar__search_events",
        "mcp__claude_ai_Google_Calendar__get_event",
        "mcp__claude_ai_Google_Calendar__list_calendars",
        // Notion
        "mcp__claude_ai_Notion__notion-search",
        "mcp__claude_ai_Notion__notion-fetch",
        "mcp__claude_ai_Notion__notion-get-comments",
        "mcp__claude_ai_Notion__notion-get-self",
        "mcp__claude_ai_Notion__notion-get-users",
        // Google Drive
        "mcp__claude_ai_Google_Drive__search_files",
        "mcp__claude_ai_Google_Drive__read_file_content",
        "mcp__claude_ai_Google_Drive__get_file_metadata",
        // Pylon
        "mcp__claude_ai_Pylon__search_issues",
        "mcp__claude_ai_Pylon__get_issue",
        "mcp__claude_ai_Pylon__get_issue_messages",
        "mcp__claude_ai_Pylon__get_me",
    ]

    /// The skill invocation. The path is Cai's own (`TodayState/`), never user
    /// text: `priorities.md` lives outside the working folder so the run can
    /// read it but not change it.
    nonisolated static func prompt(priorities: URL) -> String {
        "/cai-today priorities: \(priorities.path)"
    }

    /// The `claude` arguments, in `dogfood-run.sh`'s order. No shell parses
    /// them, so the entries with spaces arrive as one argument each.
    nonisolated static func arguments(priorities: URL) -> [String] {
        ["-p", prompt(priorities: priorities), "--permission-mode", "acceptEdits", "--allowedTools"]
            + allowedTools
            + ["--settings", #"{"disableAllHooks": true}"#, "--output-format", "stream-json", "--verbose"]
    }

    private nonisolated static let fixedTools: Set<String> = [
        "Read", "Glob", "Grep", "Skill", "Bash(date:*)",
        "Bash(mv items.jsonl.tmp items.jsonl)",
        "Bash(mv candidates.json.tmp candidates.json)",
    ]
    /// `gh` read shapes: `auth status`, `search …`, and list/view/status of
    /// pull requests and issues. Not `gh api`, which can send any method.
    private nonisolated static func isGhRead(_ tool: String) -> Bool {
        guard tool.hasPrefix("Bash(gh "), tool.hasSuffix(")") else { return false }
        let command = tool.dropFirst("Bash(gh ".count).dropLast()
        if command == "auth status" || command == "search:*" { return true }
        let words = command.split(separator: " ")
        return words.count == 2 && ["pr", "issue"].contains(words[0])
            && ["list:*", "view:*", "status:*"].contains(words[1])
    }
    private nonisolated static let connectorNames: Set<String> = [
        "Slack", "Gmail", "Google_Calendar", "Notion", "Google_Drive", "Pylon",
    ]
    private nonisolated static let readVerbs: Set<String> = ["search", "read", "get", "list", "fetch"]
    private nonisolated static let writeWords: Set<String> = [
        "send", "post", "reply", "create", "update", "delete", "forward", "trash", "label", "merge",
        "comment", "share", "upload", "schedule", "react", "reaction", "move", "restore", "resolve",
        "spawn", "stop", "write", "add", "save", "set", "apply", "mark", "cancel", "respond",
        "snooze", "publish", "manage", "execute", "submit", "edit", "remove", "archive", "invite",
        "draft", "copy", "link",
    ]

    /// Whether one allow-list entry has a read-only shape:
    /// - one of the fixed file tools, or a known `gh` read subcommand;
    /// - or a named tool of a known connector whose name starts with a read
    ///   verb (after the connector's own prefix, as in `slack_search_…`) and
    ///   contains no write word. A wildcard never passes.
    nonisolated static func isReadOnly(_ tool: String) -> Bool {
        if fixedTools.contains(tool) || isGhRead(tool) { return true }
        let prefix = "mcp__claude_ai_"
        guard tool.hasPrefix(prefix), let split = tool.range(of: "__", range: tool.index(tool.startIndex, offsetBy: prefix.count)..<tool.endIndex) else {
            return false
        }
        let connector = String(tool[tool.index(tool.startIndex, offsetBy: prefix.count)..<split.lowerBound])
        let name = String(tool[split.upperBound...])
        guard connectorNames.contains(connector), !name.isEmpty,
              name.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-" }) else { return false }
        var words = name.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        if let first = words.first, ["slack", "notion"].contains(first) { words.removeFirst() }
        guard let verb = words.first, readVerbs.contains(verb) else { return false }
        return words.allSatisfy { !writeWords.contains($0) }
    }

    /// The process environment for `claude`: the login shell's PATH (so `gh`
    /// and MCP servers resolve as in the user's terminal), minus the variables
    /// a parent Claude Code session sets. Cai launched from inside a Claude
    /// Code session (a QA run) would otherwise pass them on, and the nested
    /// run then loads none of the user's claude.ai connectors.
    nonisolated static func environment(base: [String: String], loginPath: String?) -> [String: String] {
        let nested = base["CLAUDECODE"] != nil
        var env = base.filter { key, _ in
            !(key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK_")
              || (nested && key == "ANTHROPIC_BASE_URL"))
        }
        env["PATH"] = loginPath ?? OutputDestinationService.shellEnvironment()["PATH"]
        return env
    }

    /// The first absolute directory in `searchPath` holding an executable
    /// `name`. Relative entries (`.`) are skipped: the working folder is not a
    /// place to pick up a binary from.
    nonisolated static func resolve(
        _ name: String, searchPath: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for dir in searchPath.split(separator: ":") where dir.hasPrefix("/") {
            let candidate = (String(dir) as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Decisions

    /// Opening Today starts a run only when the list exists and is over
    /// `staleAfter` old, nothing is running, and no run started in the last
    /// `staleAfter`: a run that failed is not retried on every open, ⌘R is.
    nonisolated static func shouldRefreshOnOpen(generated: Date?, lastStarted: Date?, running: Bool, now: Date) -> Bool {
        guard let generated, !running, now.timeIntervalSince(generated) > staleAfter else { return false }
        if let lastStarted, now.timeIntervalSince(lastStarted) < staleAfter { return false }
        return true
    }

    /// What a finished run means for the header. Success needs a result event
    /// that is not an error and a clean exit; anything else is a failure with
    /// a reason, so a broken run never reads as a fresh list.
    nonisolated static func outcome(result: RunResult?, status: Int32, timedOut: Bool, stderr: String) -> Phase {
        if timedOut { return .failed(reason: "Took longer than \(Int(timeout / 60)) minutes and was stopped") }
        if let result, result.isError {
            return .failed(reason: result.errorText ?? "Claude Code reported an error")
        }
        if result != nil, status == 0 { return .idle }
        let firstLine = stderr.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) }
        return .failed(reason: firstLine ?? "Claude Code exited with code \(status)")
    }

    /// One stream-json line, when it is the init or the result event.
    nonisolated static func event(fromLine line: String) -> Event? {
        guard line.contains("\"init\"") || line.contains("\"result\""),
              let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        if type == "system", object["subtype"] as? String == "init" {
            let servers = object["mcp_servers"] as? [[String: Any]] ?? []
            return .initialized(servers.compactMap { server in
                guard let name = server["name"] as? String, let status = server["status"] as? String else { return nil }
                return Connector(name: name, status: status)
            })
        }
        guard type == "result" else { return nil }
        let subtype = object["subtype"] as? String
        let isError = object["is_error"] as? Bool == true || (subtype != nil && subtype != "success")
        let denials = object["permission_denials"] as? [[String: Any]] ?? []
        let errorText = isError
            ? ((object["result"] as? String).flatMap { $0.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) } }
               ?? subtype.map { "Claude Code stopped: \($0)" })
            : nil
        return .finished(RunResult(
            durationMs: (object["duration_ms"] as? NSNumber)?.intValue,
            costUSD: (object["total_cost_usd"] as? NSNumber)?.doubleValue,
            turns: (object["num_turns"] as? NSNumber)?.intValue,
            isError: isError,
            errorText: errorText,
            denied: denials.compactMap { denial in
                guard let name = denial["tool_name"] as? String else { return nil }
                guard name == "Bash" else { return name }
                let command = (denial["tool_input"] as? [String: Any])?["command"] as? String ?? ""
                return "Bash: " + command.prefix(80)
            }
        ))
    }

    /// The `runs.log` line, the shape `dogfood-run.sh` writes: `at`,
    /// `seconds`, `cost_usd`, `turns`, `denied`. Never the result text.
    nonisolated static func logLine(at: Date, result: RunResult?, wallSeconds: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let entry: [String: Any] = [
            "at": formatter.string(from: at),
            "seconds": result?.durationMs.map { $0 / 1000 } ?? Int(wallSeconds),
            "cost_usd": result?.costUSD ?? NSNull(),
            "turns": result?.turns ?? NSNull(),
            "denied": Array(Set(result?.denied ?? [])).sorted(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Stream reading

/// Splits stdout into lines as it arrives and keeps only the init and result
/// events. Fed on `ShellRunner`'s read queue and read once after exit; the
/// lock covers both. A line past `maxLine` (a huge tool result) is skipped
/// rather than buffered: neither event Cai reads comes near that size.
private final class StreamCollector: @unchecked Sendable {
    private static let maxLine = 8 * 1024 * 1024
    private let lock = NSLock()
    private var buffer = Data()
    private var skipping = false
    private var initialized: [TodayRunner.Connector]?
    private var result: TodayRunner.RunResult?

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if skipping {
                skipping = false
            } else {
                handle(line)
            }
        }
        if buffer.count > Self.maxLine {
            buffer.removeAll()
            skipping = true
        }
    }

    func finish() -> ([TodayRunner.Connector]?, TodayRunner.RunResult?) {
        lock.lock()
        defer { lock.unlock() }
        if !skipping, !buffer.isEmpty { handle(buffer) }
        buffer.removeAll()
        return (initialized, result)
    }

    private func handle(_ line: Data) {
        switch TodayRunner.event(fromLine: String(decoding: line, as: UTF8.self)) {
        case .initialized(let connectors): initialized = connectors
        case .finished(let finished): result = finished
        case nil: break
        }
    }
}
