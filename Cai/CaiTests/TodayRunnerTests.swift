import XCTest
@testable import Cai

final class TodayRunnerTests: XCTestCase {
    private let priorities = URL(fileURLWithPath: "/Users/me/Library/Application Support/Cai/TodayState/priorities.md")

    // MARK: - (P0) The run can't be widened into one that acts

    /// Locks down: the arguments Cai passes `claude` never hand it a shell or
    /// a way past the allow list. Any of these turns the read-only refresh
    /// into a run that can do whatever a message it reads asks for.
    func testArgumentsNeverBypassPermissions() {
        let args = TodayRunner.arguments(priorities: priorities)
        let forbidden: Set<String> = [
            "--dangerously-skip-permissions", "bypassPermissions", "--allow-dangerously-skip-permissions",
            "Bash", "Bash(*)", "Bash(gh:*)", "Bash(gh *)", "-c", "/bin/sh", "/bin/zsh", "/bin/bash", "sh", "zsh", "bash",
        ]
        for arg in args {
            XCTAssertFalse(forbidden.contains(arg), "forbidden argument: \(arg)")
            XCTAssertFalse(arg.contains("bypassPermissions") || arg.contains("skip-permissions"), arg)
        }
        let pairs: [(flag: String, value: String)] = [
            ("-p", "/cai-today priorities: /Users/me/Library/Application Support/Cai/TodayState/priorities.md"),
            ("--permission-mode", "acceptEdits"),
            ("--settings", #"{"disableAllHooks": true}"#),
            ("--output-format", "stream-json"),
        ]
        for pair in pairs {
            guard let index = args.firstIndex(of: pair.flag) else { return XCTFail("missing \(pair.flag)") }
            XCTAssertEqual(args[safe: index + 1], pair.value, pair.flag)
            XCTAssertEqual(args.filter { $0 == pair.flag }.count, 1, "\(pair.flag) appears once")
        }
    }

    // MARK: - (P0) Cai's own files stay out of the run's working folder

    /// Locks down: `acceptEdits` lets the run edit anything in its working
    /// folder, so the user's done/snoozed state, the event log, the run log
    /// and their priorities must live elsewhere. And the one-time move out of
    /// the old folder never overwrites a file already in the new one.
    func testOwnedFilesLiveOutsideTheWorkingFolder() throws {
        XCTAssertNotEqual(TodayStore.stateFolder.standardizedFileURL, TodayStore.folder.standardizedFileURL)
        XCTAssertFalse(TodayStore.stateFolder.path.hasPrefix(TodayStore.folder.path + "/"))
        XCTAssertEqual(TodayStore.prioritiesURL.deletingLastPathComponent(), TodayStore.stateFolder)
        XCTAssertEqual(TodayStore.runsLogURL.deletingLastPathComponent(), TodayStore.stateFolder)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Today"), new = root.appendingPathComponent("TodayState")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        // (file, in old, in new, expected content in new, still in old)
        let cases: [(name: String, old: String?, new: String?, expected: String?, leftInOld: Bool)] = [
            ("state.json", "old state", nil, "old state", false),
            ("events.jsonl", "old events", "new events", "new events", true),
            ("runs.log", nil, "new log", "new log", false),
            ("priorities.md", nil, nil, nil, false),
        ]
        for c in cases {
            if let text = c.old { try text.write(to: old.appendingPathComponent(c.name), atomically: true, encoding: .utf8) }
            if let text = c.new { try text.write(to: new.appendingPathComponent(c.name), atomically: true, encoding: .utf8) }
        }
        TodayStore.migrate(cases.map(\.name), from: old, to: new)
        TodayStore.migrate(cases.map(\.name), from: old, to: new)  // a second open changes nothing
        for c in cases {
            XCTAssertEqual(try? String(contentsOf: new.appendingPathComponent(c.name), encoding: .utf8), c.expected, c.name)
            XCTAssertEqual(FileManager.default.fileExists(atPath: old.appendingPathComponent(c.name).path), c.leftInOld, c.name)
        }
        XCTAssertEqual(Set(TodayStore.ownedFiles), ["state.json", "events.jsonl", "runs.log", "priorities.md"])
    }

    // MARK: - (P1) A timeout reaches the whole process tree

    /// Locks down: the walk finds grandchildren too (MCP servers started by a
    /// helper), doesn't include the root, and ends on a pid cycle.
    func testDescendantWalk() {
        let cases: [(name: String, tree: [pid_t: [pid_t]], expected: [pid_t])] = [
            ("no children", [:], []),
            ("children and grandchildren", [10: [11, 12], 11: [13], 13: [14]], [11, 12, 13, 14]),
            ("cycle back to root", [10: [11], 11: [10, 12]], [11, 12]),
            ("zero pid ignored", [10: [0, 11]], [11]),
        ]
        for c in cases {
            XCTAssertEqual(ShellRunner.descendants(of: 10) { c.tree[$0] ?? [] }, c.expected, c.name)
        }
    }

    // MARK: - (P1) Every allowed tool is reviewed and read-only

    /// Locks down: the allow list passed to `claude` is exactly the reviewed
    /// table, and every entry has a read-only shape. A write tool, a whole
    /// connector or a broad `gh` pattern slipping in is what the shape check
    /// refuses; the bad rows below prove it does.
    func testAllowListIsReadOnly() {
        let args = TodayRunner.arguments(priorities: priorities)
        guard let start = args.firstIndex(of: "--allowedTools"), let end = args.firstIndex(of: "--settings") else {
            return XCTFail("no --allowedTools")
        }
        let passed = Array(args[(start + 1)..<end])
        XCTAssertEqual(passed, TodayRunner.allowedTools)
        XCTAssertFalse(passed.isEmpty)
        for tool in passed {
            XCTAssertTrue(TodayRunner.isReadOnly(tool), "not a read-only shape: \(tool)")
        }

        let refused = [
            "Bash", "Bash(*)", "Bash(gh:*)", "Bash(gh *)", "Bash(gh api:*)", "Bash(gh pr merge:*)",
            "Bash(gh pr comment:*)", "Bash(gh issue create:*)", "Bash(gh pr list:*) && rm -rf ~",
            "Bash(mv:*)", "Bash(rm:*)", "Write", "Edit", "WebFetch",
            "mcp__claude_ai_Slack", "mcp__claude_ai_Slack__*", "mcp__claude_ai_Slack__slack_send_message",
            "mcp__claude_ai_Slack__slack_send_message_draft", "mcp__claude_ai_Slack__slack_add_reaction",
            "mcp__claude_ai_Slack__slack_schedule_message", "mcp__claude_ai_Slack__slack_update_canvas",
            "mcp__claude_ai_Gmail__create_draft", "mcp__claude_ai_Gmail__reply", "mcp__claude_ai_Gmail__forward",
            "mcp__claude_ai_Gmail__trash_thread", "mcp__claude_ai_Gmail__label_message",
            "mcp__claude_ai_Google_Calendar__create_event", "mcp__claude_ai_Google_Calendar__respond_to_event",
            "mcp__claude_ai_Notion__notion-update-page", "mcp__claude_ai_Notion__notion-create-comment",
            "mcp__claude_ai_Notion__notion-move-pages", "mcp__claude_ai_Notion__notion-spawn-session",
            "mcp__claude_ai_Google_Drive__share_file", "mcp__claude_ai_Google_Drive__copy_file",
            "mcp__claude_ai_Pylon__send_issue_reply", "mcp__claude_ai_Pylon__snooze_issue",
            "mcp__claude_ai_Pylon__update_issue", "mcp__claude_ai_Pylon__get_issue_and_delete",
            "mcp__claude_ai_HubSpot__search_crm_objects", "mcp__claude_ai_Linear__list_issues",
            "mcp__kestra__search", "mcp__cai__create_action",
        ]
        for tool in refused {
            XCTAssertFalse(TodayRunner.isReadOnly(tool), "should be refused: \(tool)")
        }
    }

    // MARK: - (P1) Reading the run's output

    /// Locks down: the init event's connector statuses and the result event's
    /// numbers are read correctly; an error result is an error even with exit
    /// code 0; and `runs.log` never carries the result text (CAI-07).
    func testEventsAndLogLine() throws {
        let initLine = #"{"type":"system","subtype":"init","mcp_servers":[{"name":"claude.ai Slack","status":"connected"},{"name":"claude.ai Linear","status":"needs-auth"}],"tools":["Read"]}"#
        XCTAssertEqual(TodayRunner.event(fromLine: initLine), .initialized([
            .init(name: "claude.ai Slack", status: "connected"),
            .init(name: "claude.ai Linear", status: "needs-auth"),
        ]))

        let ok = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":107400,"total_cost_usd":1.2,"num_turns":36,"result":"Wrote 4 items: Reply to Alex about the Q4 numbers","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"gh api repos/x/y"}},{"tool_name":"mcp__claude_ai_Slack__slack_send_message","tool_input":{"text":"hi"}}]}"#
        let errored = #"{"type":"result","subtype":"success","is_error":true,"duration_ms":900,"num_turns":1,"result":"Not logged in · Please run /login\nmore","permission_denials":[]}"#
        let maxTurns = #"{"type":"result","subtype":"error_max_turns","duration_ms":5000,"num_turns":50}"#

        let cases: [(name: String, line: String, isError: Bool?, errorText: String?, seconds: Int?, denied: [String])] = [
            ("success", ok, false, nil, 107, ["Bash: gh api repos/x/y", "mcp__claude_ai_Slack__slack_send_message"]),
            ("is_error wins over subtype", errored, true, "Not logged in · Please run /login", 0, []),
            ("non-success subtype is an error", maxTurns, true, "Claude Code stopped: error_max_turns", 5, []),
            ("assistant message is ignored", #"{"type":"assistant","message":{"content":"result"}}"#, nil, nil, nil, []),
            ("not JSON", "result: oops", nil, nil, nil, []),
        ]
        for c in cases {
            let event = TodayRunner.event(fromLine: c.line)
            guard let isError = c.isError else {
                XCTAssertNil(event, c.name)
                continue
            }
            guard case .finished(let result) = event else { return XCTFail(c.name) }
            XCTAssertEqual(result.isError, isError, c.name)
            XCTAssertEqual(result.errorText, c.errorText, c.name)
            XCTAssertEqual(result.durationMs.map { $0 / 1000 }, c.seconds, c.name)
            XCTAssertEqual(result.denied, c.denied, c.name)

            let line = TodayRunner.logLine(at: Date(timeIntervalSince1970: 0), result: result, wallSeconds: 1)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["at", "seconds", "cost_usd", "turns", "denied"], c.name)
            XCTAssertFalse(line.contains("Q4") || line.contains("logged in"), "result text leaked into runs.log: \(c.name)")
        }
    }

    // MARK: - (P0) A failed run never reads as a fresh list

    /// Locks down: the header says "Couldn't refresh" whenever the run did
    /// not finish cleanly. Showing the old list as updated would be a lie the
    /// user acts on.
    func testOutcome() {
        let good = TodayRunner.RunResult(durationMs: 1000, costUSD: 1, turns: 3, isError: false, errorText: nil, denied: [])
        var bad = good
        bad.isError = true
        bad.errorText = "Credit balance is too low"
        let cases: [(name: String, result: TodayRunner.RunResult?, status: Int32, timedOut: Bool, stderr: String, expected: TodayRunner.Phase)] = [
            ("clean run", good, 0, false, "", .idle),
            ("error result, exit 0", bad, 0, false, "", .failed(reason: "Credit balance is too low")),
            ("timed out, even with a result", good, 0, true, "", .failed(reason: "Took longer than 20 minutes and was stopped")),
            ("no result event, exit 0", nil, 0, false, "", .failed(reason: "Claude Code exited with code 0")),
            ("crash, stderr first line", nil, 1, false, "error: unknown option\nusage…", .failed(reason: "error: unknown option")),
            ("good result, non-zero exit", good, 2, false, "", .failed(reason: "Claude Code exited with code 2")),
        ]
        for c in cases {
            XCTAssertEqual(TodayRunner.outcome(result: c.result, status: c.status, timedOut: c.timedOut, stderr: c.stderr), c.expected, c.name)
        }
    }

    // MARK: - (P1) Refresh on open

    /// Locks down: opening Today refreshes only a list over 2 hours old, never
    /// with no list or while a run is going, and a failed run isn't retried
    /// on every open (each run costs the user money).
    func testRefreshOnOpen() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let hour: TimeInterval = 3600
        let cases: [(name: String, generated: Date?, lastStarted: Date?, running: Bool, expected: Bool)] = [
            ("3 h old list", now - 3 * hour, nil, false, true),
            ("1 h old list", now - 1 * hour, nil, false, false),
            ("no list", nil, nil, false, false),
            ("already running", now - 3 * hour, now - 60, true, false),
            ("a run started 10 min ago and failed", now - 3 * hour, now - 600, false, false),
            ("last run started 3 h ago", now - 5 * hour, now - 3 * hour, false, true),
        ]
        for c in cases {
            XCTAssertEqual(TodayRunner.shouldRefreshOnOpen(generated: c.generated, lastStarted: c.lastStarted, running: c.running, now: now), c.expected, c.name)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
