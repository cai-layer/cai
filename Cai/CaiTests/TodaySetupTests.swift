import XCTest
@testable import Cai

final class TodaySetupTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("TodaySetupTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - (P0) Adding the skill never overwrites the user's skill

    /// Locks down: step 1 writes `~/.claude/skills/cai-today/` only when
    /// nothing is there. An edited copy, a link to a dev checkout (even a
    /// broken one) or a stray file is left byte for byte as it was; a copy
    /// identical to the bundled one is not written again.
    func testInstallDecisionTable() throws {
        let bundled = root.appendingPathComponent("bundled")
        try write("skill v1", "SKILL.md", in: bundled)
        try write("format", "reference/format.md", in: bundled)
        let elsewhere = root.appendingPathComponent("worktree-skill")
        try write("dev skill", "SKILL.md", in: elsewhere)
        let linkedSkills = root.appendingPathComponent("dotfiles-skills")
        try fm.createDirectory(at: linkedSkills, withIntermediateDirectories: true)

        let cases: [(name: String, prepare: (URL) throws -> Void, existing: TodaySkill.Existing, decision: TodaySkill.Decision)] = [
            ("missing", { _ in }, .missing, .install),
            ("identical", { try self.fm.copyItem(at: bundled, to: $0) }, .identical, .skip),
            ("edited", { url in
                try self.fm.copyItem(at: bundled, to: url)
                try self.write("skill v1, with my edits", "SKILL.md", in: url)
            }, .differs, .leaveAndSay),
            ("extra file", { url in
                try self.fm.copyItem(at: bundled, to: url)
                try self.write("mine", "notes.md", in: url)
            }, .differs, .leaveAndSay),
            ("a file, not a folder", { try "x".write(to: $0, atomically: true, encoding: .utf8) }, .differs, .leaveAndSay),
            ("symlink", { try self.fm.createSymbolicLink(at: $0, withDestinationURL: elsewhere) }, .symlink, .keep),
            ("broken symlink", { try self.fm.createSymbolicLink(at: $0, withDestinationURL: self.root.appendingPathComponent("gone")) }, .symlink, .keep),
            ("skills folder is a link", { url in
                let parent = url.deletingLastPathComponent()
                try self.fm.removeItem(at: parent)
                try self.fm.createSymbolicLink(at: parent, withDestinationURL: linkedSkills)
            }, .missing, .linkedFolder),
        ]
        for c in cases {
            let installed = root.appendingPathComponent("skills-\(c.name)/cai-today")
            try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try c.prepare(installed)
            let before = TodaySkill.contentHash(of: installed)
            let attributesBefore = try? fm.attributesOfItem(atPath: installed.path)

            XCTAssertEqual(TodaySkill.inspect(installed, bundled: bundled), c.existing, c.name)
            XCTAssertEqual(try TodaySkill.addIfSafe(bundled: bundled, to: installed), c.decision, c.name)

            if c.decision == .install {
                XCTAssertEqual(TodaySkill.contentHash(of: installed), TodaySkill.contentHash(of: bundled), c.name)
                XCTAssertTrue(fm.fileExists(atPath: installed.appendingPathComponent("reference/format.md").path), "\(c.name): structure kept")
            } else {
                XCTAssertEqual(TodaySkill.contentHash(of: installed), before, "\(c.name): untouched")
                XCTAssertEqual((try? fm.attributesOfItem(atPath: installed.path))?[.type] as? FileAttributeType,
                               attributesBefore?[.type] as? FileAttributeType, "\(c.name): same kind of item")
            }
        }
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent("SKILL.md"), encoding: .utf8), "dev skill")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: linkedSkills.path), [], "nothing written through a linked skills folder")
    }

    // MARK: - (P1) Turning a source off removes its tools, and only its tools

    /// Locks down: the enabled sources narrow the run by its allow list. A
    /// source the user turned off keeps none of its tools (the run can't read
    /// it however the prompt reads), and no other source or file tool is lost.
    /// Every non-file tool must belong to a source, or turning it off would
    /// miss it. Server names from the init event map to the same sources.
    func testSourceFilterOnTheAllowList() {
        let all = TodayRunner.allowedTools
        let fileTools = all.filter { TodaySource.owner(ofAllowedTool: $0) == nil }
        XCTAssertEqual(Set(fileTools), ["Read", "Glob", "Grep", "Skill", "Bash(date:*)",
                                         "Bash(mv items.jsonl.tmp items.jsonl)", "Bash(mv candidates.json.tmp candidates.json)"])
        XCTAssertEqual(TodayRunner.allowedTools(enabled: nil), all)
        XCTAssertEqual(TodayRunner.allowedTools(enabled: []), fileTools)

        let priorities = URL(fileURLWithPath: "/tmp/priorities.md")
        for source in TodaySource.allCases {
            let kept = TodayRunner.allowedTools(enabled: Set(TodaySource.allCases).subtracting([source]))
            let removed = all.filter { !kept.contains($0) }
            XCTAssertFalse(removed.isEmpty, "\(source) owns tools")
            XCTAssertTrue(removed.allSatisfy { TodaySource.owner(ofAllowedTool: $0) == source }, "\(source): only its own tools go")
            XCTAssertEqual(kept, all.filter { TodaySource.owner(ofAllowedTool: $0) != source }, "\(source): the rest stay, in order")
            let args = TodayRunner.arguments(priorities: priorities, enabled: Set(TodaySource.allCases).subtracting([source]))
            XCTAssertTrue(Set(args).isDisjoint(with: removed), "\(source) tools reach the arguments")
        }

        let servers: [(String, TodaySource?)] = [
            ("claude.ai Slack", .slack), ("claude.ai Google Calendar", .calendar), ("claude.ai Google Drive", .drive),
            ("claude.ai Pylon", .pylon), ("Slack", nil), ("example", nil), ("claude.ai Linear", nil),
        ]
        for (name, source) in servers {
            XCTAssertEqual(TodaySource.owner(ofServer: name), source, name)
        }
    }

    // MARK: - (P0) An unreadable sources.json never widens the run

    /// Locks down: a sources.json that is there but can't be read, or is a
    /// version this build doesn't know, stops the run ("Check Settings →
    /// Today → Tools") instead of reading every tool. Only a missing file
    /// means the whole reviewed table.
    func testSourcesFailClosed() throws {
        let fileTools = TodayRunner.allowedTools.filter { TodaySource.owner(ofAllowedTool: $0) == nil }
        let slackOnly = TodayRunner.allowedTools.filter { [nil, .slack].contains(TodaySource.owner(ofAllowedTool: $0)) }
        let cases: [(name: String, prepare: (URL) throws -> Void, saved: TodaySourceSettings.Saved, tools: [String]?)] = [
            ("no file: the whole table", { _ in }, .missing, TodayRunner.allowedTools),
            ("v1, Slack on", { try TodaySourceSettings.encode([.slack]).write(to: $0) }, .enabled([.slack]), slackOnly),
            ("v1, nothing on", { try TodaySourceSettings.encode([]).write(to: $0) }, .enabled([]), fileTools),
            ("unknown version", { try Data(#"{"v":2,"enabled":["slack"]}"#.utf8).write(to: $0) }, .unreadable, nil),
            ("not JSON", { try Data("slack".utf8).write(to: $0) }, .unreadable, nil),
            ("enabled isn't a list", { try Data(#"{"v":1,"enabled":"slack"}"#.utf8).write(to: $0) }, .unreadable, nil),
            ("a folder", { try self.fm.createDirectory(at: $0, withIntermediateDirectories: false) }, .unreadable, nil),
            ("can't be read", { url in
                try TodaySourceSettings.encode([.slack]).write(to: url)
                try self.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            }, .unreadable, nil),
        ]
        for c in cases {
            let url = root.appendingPathComponent("sources-\(c.name).json")
            try c.prepare(url)
            defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            let saved = TodaySourceSettings.read(url)
            XCTAssertEqual(saved, c.saved, c.name)
            let enabled = TodayRunner.enabledSources(saved)
            XCTAssertEqual(enabled.map { TodayRunner.allowedTools(enabled: $0) }, c.tools, c.name)
        }
    }

    // MARK: - (P1) Type-ahead

    /// Locks down: suggestions match word starts like the action-list filter,
    /// ignore case and accents, `#` keeps only channels, anything already in
    /// the list (by name or email) never comes up again, and there are at
    /// most five.
    func testTypeAheadMatchingAndExclusions() {
        let p = { (name: String, detail: String?) in TodaySuggestion(kind: .person, name: name, detail: detail, from: "Slack") }
        let c = { (name: String) in TodaySuggestion(kind: .channel, name: name, detail: nil, from: "Slack") }
        let candidates = [
            p("Asís Ybarra", "asis@northwind.co"), c("#ask-cloud"), p("Ana Ortega", "@ana.o"),
            p("Laura Pérez", "laura.perez@northwind.co"), c("#asia-sales"), p("Tomás Aspas", "tomas@northwind.co"),
            c("#ops-alerts"), p("Marta Ruiz", nil), p("Jonas Becker", "jonas@legal.co"),
        ]
        let entries = [
            TodayPriorityEntry(kind: .person, name: "Marta Ruiz", reason: ""),
            TodayPriorityEntry(kind: .channel, name: "#ops-alerts", reason: ""),
            TodayPriorityEntry(kind: .person, name: "jonas@legal.co", reason: ""),
        ]
        let cases: [(query: String, expected: [String])] = [
            ("as", ["Asís Ybarra", "#ask-cloud", "#asia-sales", "Tomás Aspas"]),
            ("AS", ["Asís Ybarra", "#ask-cloud", "#asia-sales", "Tomás Aspas"]),
            ("#as", ["#ask-cloud", "#asia-sales"]),
            ("asi", ["Asís Ybarra", "#asia-sales"]),
            ("@ana", ["Ana Ortega"]),
            ("laura p", ["Laura Pérez"]),
            ("ote", []),
            ("marta", []),
            ("#ops", []),
            ("jonas", []),
            ("", []),
        ]
        for c in cases {
            XCTAssertEqual(TodayPriorities.suggestions(for: c.query, in: candidates, excluding: entries).map(\.name), c.expected, c.query)
        }
        let many = (1...9).map { p("Alex \($0)", nil) }
        XCTAssertEqual(TodayPriorities.suggestions(for: "alex", in: many, excluding: []).count, 5)
    }

    // MARK: - (P1) priorities.md

    /// Locks down: step 4 writes the template's format. Stars come back as
    /// stars, channels get their `#`, the template's commented examples stay
    /// comments (so the skill never reads them as entries), the user's other
    /// sections survive a rewrite, writing twice doesn't duplicate, and a name
    /// can't open a comment or a line of its own.
    func testPrioritiesRoundTrip() throws {
        let templateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/cai-today/priorities.template.md")
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        XCTAssertTrue(TodayPriorities.parse(template).isEmpty, "the template's examples are comments")

        let entries = [
            TodayPriorityEntry(kind: .person, name: "Marta Ruiz", reason: "Your manager", starred: true),
            TodayPriorityEntry(kind: .person, name: "jonas@northwind-legal.co", reason: ""),
            TodayPriorityEntry(kind: .person, name: "@priya-dev", reason: "", starred: true),
            TodayPriorityEntry(kind: .person, name: "Eve <!-- hidden\n- * Mallory", reason: ""),
            TodayPriorityEntry(kind: .channel, name: "#leadership", reason: ""),
            TodayPriorityEntry(kind: .channel, name: "release-1-7", reason: ""),
        ]
        let written = TodayPriorities.render(entries, into: template)
        let expected: [(TodayPriorityEntry.Kind, String, Bool)] = [
            (.person, "Marta Ruiz", true), (.person, "jonas@northwind-legal.co", false), (.person, "@priya-dev", true),
            (.person, "Eve  hidden - * Mallory", false), (.channel, "#leadership", false), (.channel, "#release-1-7", false),
        ]
        let parsed = TodayPriorities.parse(written)
        XCTAssertEqual(parsed.map(\.kind), expected.map(\.0))
        XCTAssertEqual(parsed.map(\.name), expected.map(\.1))
        XCTAssertEqual(parsed.map(\.starred), expected.map(\.2))
        XCTAssertTrue(written.contains("- * Marta Ruiz\n"))

        let commentLines = template.components(separatedBy: "\n").filter { $0.hasPrefix("<!--") }
        let writtenLines = written.components(separatedBy: "\n")
        for line in commentLines { XCTAssertTrue(writtenLines.contains(line), "comment kept: \(line)") }

        let edited = written + "\n- https://www.notion.so/team/Roadmap\n"
        let rewritten = TodayPriorities.render(Array(entries.prefix(1)), into: edited)
        XCTAssertEqual(TodayPriorities.parse(rewritten).map(\.name), ["Marta Ruiz"])
        XCTAssertTrue(rewritten.contains("- https://www.notion.so/team/Roadmap"), "other sections survive")
        XCTAssertEqual(TodayPriorities.render(entries, into: written), written, "writing twice changes nothing")
    }

    /// Locks down: a `<!-- … -->` comment over several lines is never read
    /// as a header, never loses its lines (even ones that look like entries)
    /// and never has entries inserted into it.
    func testRenderKeepsMultiLineComments() {
        let base = """
        ## People
        <!-- Examples:
        - * Someone Example
        ## Slack channels
        -->
        - Old Person

        ## Slack channels
        <!--
        - #example
        -->
        - #old
        """
        let written = TodayPriorities.render([
            TodayPriorityEntry(kind: .person, name: "Marta Ruiz", reason: ""),
            TodayPriorityEntry(kind: .channel, name: "#leadership", reason: ""),
        ], into: base)
        let expected = """
        ## People
        <!-- Examples:
        - * Someone Example
        ## Slack channels
        -->
        - Marta Ruiz

        ## Slack channels
        <!--
        - #example
        -->
        - #leadership
        """
        XCTAssertEqual(written, expected)
        XCTAssertEqual(TodayPriorities.render([], into: base).components(separatedBy: "\n").filter { $0.hasPrefix("- ") },
                       ["- * Someone Example", "- #example"], "comment lines survive an empty list")
    }

    // MARK: - (P1) Closing the panel never loses setup

    /// Locks down: setup reopens on the step it left however long the panel
    /// was closed (a tool check or a first build is never dropped), and the
    /// action list says so, under proposals and above an update.
    func testSetupSurvivesClosingThePanel() {
        typealias Step = TodaySetup.Step
        let resumes: [(current: Step?, listMissing: Bool, expected: Step?)] = [
            (.skill, true, .skill),
            (.tools, true, .tools),
            (.building, true, .building),
            (.people, false, .people),
            (.intro, true, .intro),
            (.intro, false, nil),
            (nil, true, .intro),
            (nil, false, nil),
        ]
        for c in resumes {
            XCTAssertEqual(TodaySetup.resumedStep(current: c.current, listMissing: c.listMissing), c.expected, "\(String(describing: c.current)) missing=\(c.listMissing)")
        }
        let pendings: [(step: Step?, building: Bool, expected: ActionListNotice.TodayPending?)] = [
            (.building, true, .building),
            (.building, false, .unfinished),
            (.tools, false, .unfinished),
            (.people, false, .unfinished),
            (.intro, false, nil),
            (nil, true, nil),
        ]
        for c in pendings {
            XCTAssertEqual(TodaySetup.pending(step: c.step, building: c.building), c.expected, "\(String(describing: c.step)) building=\(c.building)")
        }
        XCTAssertEqual(ActionListNotice.active(pendingProposals: 1, today: .building, updateAvailable: true, crashPromptShown: false), .proposals(count: 1))
        XCTAssertEqual(ActionListNotice.active(pendingProposals: 0, today: .building, updateAvailable: true, crashPromptShown: false), .today(.building))
    }
}
