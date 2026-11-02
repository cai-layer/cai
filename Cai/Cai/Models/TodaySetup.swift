import CryptoKit
import Foundation

// The pure parts of Today's first-run setup: which tools belong to which
// source, the skill install decision, the "who matters most" proposal,
// type-ahead and `priorities.md`. Every function here is table-tested in
// `TodaySetupTests`; the screen and the IO live in `TodaySetupView`.

// MARK: - Sources

/// A tool the `cai-today` run can read. Each owns a slice of
/// `TodayRunner.allowedTools`; a source the user turns off loses that slice.
enum TodaySource: String, CaseIterable {
    case slack, gmail, calendar, notion, drive, pylon, github

    var title: String {
        switch self {
        case .slack: return "Slack"
        case .gmail: return "Gmail"
        case .calendar: return "Google Calendar"
        case .notion: return "Notion"
        case .drive: return "Google Drive"
        case .pylon: return "Pylon"
        case .github: return "GitHub"
        }
    }

    /// The claude.ai connector's name as it appears in tool names
    /// (`mcp__claude_ai_<connector>__…`). GitHub is read with `gh` instead.
    var connector: String? {
        switch self {
        case .slack: return "Slack"
        case .gmail: return "Gmail"
        case .calendar: return "Google_Calendar"
        case .notion: return "Notion"
        case .drive: return "Google_Drive"
        case .pylon: return "Pylon"
        case .github: return nil
        }
    }

    /// The source an allow-list entry belongs to, or nil for the file tools
    /// every run needs.
    static func owner(ofAllowedTool tool: String) -> TodaySource? {
        if tool.hasPrefix("Bash(gh ") { return .github }
        return allCases.first { source in
            source.connector.map { tool.hasPrefix("mcp__claude_ai_\($0)__") } ?? false
        }
    }

    /// The source a tool call in the run's stream reads, for setup's progress
    /// rows. `command` is the Bash command when the tool is Bash.
    static func owner(ofToolUse name: String, command: String?) -> TodaySource? {
        if name == "Bash" { return command?.hasPrefix("gh ") == true ? .github : nil }
        return owner(ofAllowedTool: name)
    }

    /// Matches an init event's server name (`claude.ai Google Calendar`) the
    /// way Claude Code builds tool names from it: anything but letters,
    /// digits, `_` and `-` becomes `_`.
    static func owner(ofServer name: String) -> TodaySource? {
        let normalized = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return allCases.first { $0.connector.map { "claude_ai_\($0)" } == normalized }
    }
}

/// What setup step 2 shows for one source.
enum TodaySourceStatus: Equatable {
    case connected
    /// The connector is there but not signed in.
    case signIn
    case unavailable

    /// From the probe's init event and `gh auth status`. A connector still
    /// `pending` after the probe's one retry reads as unavailable.
    static func of(_ source: TodaySource, servers: [(name: String, status: String)], ghSignedIn: Bool) -> TodaySourceStatus {
        if source == .github { return ghSignedIn ? .connected : .unavailable }
        guard let server = servers.first(where: { TodaySource.owner(ofServer: $0.name) == source }) else { return .unavailable }
        switch server.status {
        case "connected": return .connected
        case "needs-auth": return .signIn
        default: return .unavailable
        }
    }

    func subtitle(for source: TodaySource) -> String {
        switch (self, source) {
        case (.connected, .github): return "Signed in with the gh command"
        case (.connected, _): return "Connected in Claude"
        case (.signIn, _): return "Sign in to \(source.title) in Claude first: Settings, Connectors"
        case (.unavailable, .github): return "Not available: sign in with gh auth login first"
        case (.unavailable, _): return "Not available in your Claude"
        }
    }
}

/// The sources the user turned on, in `TodayState/sources.json`. A file next
/// to Cai's other Today state rather than a CaiSettings key: Debug and Release
/// share `TodayState/`, so a refresh from either build reads the same tools,
/// and the file carries `v` like every other Today file.
enum TodaySourceSettings {
    static var url: URL { TodayStore.stateFolder.appendingPathComponent("sources.json") }

    /// Nil when there is no file (setup never ran, so the run keeps the whole
    /// reviewed table) or it isn't a version this build reads. Unknown source
    /// names are ignored, so a newer build's file still narrows.
    static func decode(_ data: Data) -> Set<TodaySource>? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["v"] as? Int == 1, let names = object["enabled"] as? [String] else { return nil }
        return Set(names.compactMap(TodaySource.init(rawValue:)))
    }

    static func encode(_ enabled: Set<TodaySource>) -> Data {
        let names = TodaySource.allCases.filter(enabled.contains).map(\.rawValue)
        let object: [String: Any] = ["v": 1, "enabled": names]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func load() -> Set<TodaySource>? {
        (try? Data(contentsOf: url)).flatMap(decode)
    }

    static func save(_ enabled: Set<TodaySource>) {
        try? FileManager.default.createDirectory(at: TodayStore.stateFolder, withIntermediateDirectories: true)
        try? encode(enabled).write(to: url, options: .atomic)
    }
}

// MARK: - The skill

/// The `cai-today` skill Cai ships in `Contents/Resources/cai-today/` and adds
/// to `~/.claude/skills/cai-today/` on the user's click.
enum TodaySkill {
    /// What is at the install path now.
    enum Existing: Equatable {
        case missing
        /// A symlink, wherever it points (a dev checkout, a dotfiles repo):
        /// installed and managed elsewhere.
        case symlink
        /// A folder byte-identical to the bundled skill.
        case identical
        /// Anything else: an edited copy, an older or newer skill, a file.
        case differs
    }

    enum Decision: Equatable {
        case install
        /// Already the bundled skill; nothing to write.
        case skip
        /// Not ours to change: say so and use it as it is.
        case leaveAndSay
        /// A link someone manages: use it as it is.
        case keep
    }

    /// (P0) Only a missing skill is ever written. Cai never overwrites a skill
    /// folder that is there, edited or not.
    static func decision(for existing: Existing) -> Decision {
        switch existing {
        case .missing: return .install
        case .identical: return .skip
        case .differs: return .leaveAndSay
        case .symlink: return .keep
        }
    }

    static var installURL: URL { TodayRunner.skillFolder }

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "cai-today", withExtension: nil)
    }

    /// The bundled skill's version: a hash of its files. PR 5's Update Skill
    /// compares it with the installed folder's hash.
    static let bundledVersion: String? = bundledURL.flatMap { contentHash(of: $0) }

    /// Reads the install path without following a symlink at its end, so a
    /// link (even a broken one) is never mistaken for a missing folder.
    static func inspect(_ installed: URL, bundled: URL, fileManager: FileManager = .default) -> Existing {
        guard let attributes = try? fileManager.attributesOfItem(atPath: installed.path) else { return .missing }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return .symlink }
        guard let mine = contentHash(of: bundled), let theirs = contentHash(of: installed) else { return .differs }
        return mine == theirs ? .identical : .differs
    }

    /// Inspects, decides, and copies only when the decision is `.install`.
    @discardableResult
    static func addIfSafe(bundled: URL, to installed: URL, fileManager: FileManager = .default) throws -> Decision {
        let decision = decision(for: inspect(installed, bundled: bundled, fileManager: fileManager))
        guard decision == .install else { return decision }
        try fileManager.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: bundled, to: installed)
        return decision
    }

    /// SHA-256 over every regular file under `folder`: relative path, then
    /// contents, in path order. `.DS_Store` is skipped (Finder writes it on
    /// open). Nil when `folder` isn't a readable directory.
    static func contentHash(of folder: URL, fileManager: FileManager = .default) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        let base = folder.resolvingSymlinksInPath().path
        var files: [(path: String, url: URL)] = []
        for case let url as URL in walker where url.lastPathComponent != ".DS_Store" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            files.append((String(full.dropFirst(base.count)), url))
        }
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: file.url) else { return nil }
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(data.count).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Who matters most

/// One line of step 4: a person or a Slack channel.
struct TodayPriorityEntry: Equatable {
    enum Kind: Equatable { case person, channel }
    var kind: Kind
    var name: String
    var reason: String
    var starred = false
}

/// A type-ahead row in step 4.
struct TodaySuggestion: Equatable {
    var kind: TodayPriorityEntry.Kind
    var name: String
    /// An email, an @handle, or nil.
    var detail: String?
    /// Where it came from: "Slack", "Gmail", "Contacts".
    var from: String
}

/// `candidates.json`, as `reference/format.md` defines it. Written by the run,
/// so every field is checked and capped before it reaches the screen.
struct TodayCandidates: Equatable {
    var people: [TodayCandidate] = []
    var channels: [TodayCandidate] = []

    static let maxPeople = 100
    static let maxChannels = 50
    static let maxField = 120

    static func parse(_ data: Data) -> TodayCandidates? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["v"] as? Int == 1 else { return nil }
        func field(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return TodayPriorities.clean(String(text.prefix(maxField)))
        }
        var parsed = TodayCandidates()
        for person in (object["people"] as? [[String: Any]] ?? []).prefix(maxPeople) {
            guard let name = field(person["name"]) else { continue }
            let from = ((person["sources"] as? [String])?.first).map(Self.sourceName) ?? "Slack"
            parsed.people.append(.init(
                suggestion: TodaySuggestion(kind: .person, name: name, detail: field(person["email"]) ?? field(person["handle"]), from: from),
                reason: field(person["reason"]) ?? ""))
        }
        for channel in (object["channels"] as? [[String: Any]] ?? []).prefix(maxChannels) {
            guard var name = field(channel["name"]) else { continue }
            if !name.hasPrefix("#") { name = "#" + name }
            parsed.channels.append(.init(
                suggestion: TodaySuggestion(kind: .channel, name: name, detail: nil, from: Self.sourceName(channel["source"] as? String ?? "slack")),
                reason: field(channel["reason"]) ?? ""))
        }
        return parsed
    }

    private static func sourceName(_ raw: String) -> String {
        TodaySource(rawValue: raw.lowercased())?.title ?? raw.capitalized
    }
}

/// A suggestion with the run's one-line reason for it.
struct TodayCandidate: Equatable {
    var suggestion: TodaySuggestion
    var reason: String
}

extension TodayCandidates {
    /// Step 4's starting list: the top people and channels with their reason.
    /// Nobody is starred by default (round 3, open question 2).
    func proposal(people peopleLimit: Int = 5, channels channelLimit: Int = 5) -> [TodayPriorityEntry] {
        people.prefix(peopleLimit).map { TodayPriorityEntry(kind: .person, name: $0.suggestion.name, reason: $0.reason) }
            + channels.prefix(channelLimit).map { TodayPriorityEntry(kind: .channel, name: $0.suggestion.name, reason: $0.reason) }
    }
}

enum TodayPriorities {
    static let peopleHeader = "## People"
    static let channelsHeader = "## Slack channels"

    /// Used when the bundled template can't be read. Same sections.
    static let fallbackTemplate = """
    <!-- cai-today priorities, v1 -->
    # Who matters most

    ## People
    <!-- One per line: a name, an email or an @handle. A * (or ★) in front ranks them first. -->

    ## Slack channels
    <!-- Read in addition to your DMs, mentions and threads. -->

    ## Also watch

    ## Topics

    """

    /// One line of user or run text, safe to write as a list entry: no line
    /// breaks, and no comment marks that would hide the lines after it.
    static func clean(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// `base` (the existing file, else the template) with the People and
    /// Slack channels entries replaced by `entries`. Everything else, comments
    /// and the other sections included, is kept line for line. New entries go
    /// right after the section's leading comment lines.
    static func render(_ entries: [TodayPriorityEntry], into base: String) -> String {
        var lines = base.components(separatedBy: "\n")
        for (header, kind) in [(peopleHeader, TodayPriorityEntry.Kind.person), (channelsHeader, .channel)] {
            let wanted = entries.filter { $0.kind == kind }.compactMap(line(for:))
            guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
                if !wanted.isEmpty { lines += ["", header] + wanted }
                continue
            }
            var end = start + 1
            while end < lines.count, !lines[end].hasPrefix("#") { end += 1 }
            var body = Array(lines[(start + 1)..<end])
            body.removeAll(where: isEntry)
            var insertAt = 0
            while insertAt < body.count, body[insertAt].trimmingCharacters(in: .whitespaces).hasPrefix("<!--") { insertAt += 1 }
            body.insert(contentsOf: wanted, at: insertAt)
            lines.replaceSubrange((start + 1)..<end, with: body)
        }
        return lines.joined(separator: "\n")
    }

    /// The People and Slack channels entries in a file, comments ignored.
    static func parse(_ text: String) -> [TodayPriorityEntry] {
        var entries: [TodayPriorityEntry] = []
        var kind: TodayPriorityEntry.Kind?
        for line in stripComments(text).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), trimmed.drop(while: { $0 == "#" }).hasPrefix(" ") {
                kind = trimmed == peopleHeader ? .person : trimmed == channelsHeader ? .channel : nil
                continue
            }
            guard let kind, trimmed.hasPrefix("- ") else { continue }
            var name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var starred = false
            if name.hasPrefix("* ") || name.hasPrefix("★ ") {
                starred = true
                name = String(name.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty else { continue }
            entries.append(TodayPriorityEntry(kind: kind, name: name, reason: "In your priorities.md", starred: starred && kind == .person))
        }
        return entries
    }

    private static func line(for entry: TodayPriorityEntry) -> String? {
        var name = clean(entry.name)
        while let first = name.first, "*★-".contains(first) { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !name.isEmpty else { return nil }
        if entry.kind == .channel, !name.hasPrefix("#") { name = "#" + name }
        return "- " + (entry.starred && entry.kind == .person ? "* " : "") + name
    }

    private static func isEntry(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
    }

    private static func stripComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<!--") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "-->") else { return result }
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    // MARK: Type-ahead

    /// Up to `limit` suggestions for `query`. Word-prefix matching like the
    /// action-list filter: every word typed must start a word of the name or
    /// its detail. A leading `#` keeps only channels; a leading `@` is
    /// dropped. Anything already in the list, by name or detail, is left out.
    static func suggestions(for query: String, in candidates: [TodaySuggestion], excluding entries: [TodayPriorityEntry], limit: Int = 5) -> [TodaySuggestion] {
        let channelsOnly = query.hasPrefix("#")
        let terms = words(query)
        guard !terms.isEmpty else { return [] }
        let taken = Set(entries.map { fold($0.name) })
        var seen = Set<String>()
        var matches: [TodaySuggestion] = []
        for candidate in candidates where matches.count < limit {
            if channelsOnly && candidate.kind != .channel { continue }
            let keys = [candidate.name, candidate.detail].compactMap { $0.map(fold) }
            if keys.contains(where: taken.contains) || !seen.insert(fold(candidate.name)).inserted { continue }
            let haystack = words("\(candidate.name) \(candidate.detail ?? "")")
            if terms.allSatisfy({ term in haystack.contains { $0.hasPrefix(term) } }) { matches.append(candidate) }
        }
        return matches
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(_ text: String) -> [String] {
        fold(text).split(whereSeparator: { $0 == " " || $0 == "#" || $0 == "@" }).map(String.init)
    }
}
