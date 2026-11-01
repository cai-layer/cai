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

    /// Nil when the data isn't a version this build reads. Unknown source
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

    /// What is at `url`. A file that is there but can't be read, or isn't a
    /// version this build reads, is `.unreadable`, never "no choice made":
    /// the run then fails closed rather than reading every tool.
    enum Saved: Equatable {
        case missing
        case enabled(Set<TodaySource>)
        case unreadable
    }

    static func read(_ file: URL = url, fileManager: FileManager = .default) -> Saved {
        guard (try? fileManager.attributesOfItem(atPath: file.path)) != nil else { return .missing }
        guard let data = try? Data(contentsOf: file), let enabled = decode(data) else { return .unreadable }
        return .enabled(enabled)
    }

    /// For setup and Settings, which rewrite the file: the saved choice, or
    /// nil when there is none they can use (missing or unreadable).
    static func load() -> Set<TodaySource>? {
        if case .enabled(let enabled) = read() { return enabled }
        return nil
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
        /// Would install, but `~/.claude` or its skills folder is a link:
        /// nothing written, the user copies it (`LinkedFolder.message`).
        case linkedFolder
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
        if linkedParent(of: installed, fileManager: fileManager) != nil { return .linkedFolder }
        try fileManager.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: bundled, to: installed)
        return decision
    }

    // MARK: Update Skill (Settings → Today)

    /// What Settings says about the installed skill.
    enum Status: Equatable {
        case notAdded
        /// The same files Cai ships.
        case current
        /// Cai ships a different version, and the installed copy is the one
        /// Cai last wrote: nobody changed it, so Update Skill may replace it.
        case updateAvailable
        /// A link: installed and managed elsewhere.
        case managedElsewhere
        /// Different from what Cai ships and from what this build last wrote:
        /// an edited copy, someone else's install, the other build's (Debug
        /// or Release) install, or a file. Not this Cai's to touch.
        case changedOutsideCai
    }

    /// The install path as Settings sees it. `folder(nil)` is something there
    /// that can't be hashed (a file, an unreadable folder).
    enum Installed: Equatable {
        case missing
        case symlink
        case folder(hash: String?)
    }

    /// (P0) Update Skill shows only when the installed copy is exactly the one
    /// Cai last installed and Cai now ships something else. A copy whose hash
    /// Cai never recorded, edited or not, is never offered for replacement.
    static func status(installed: Installed, bundled: String?, lastInstalled: String?) -> Status {
        switch installed {
        case .missing: return .notAdded
        case .symlink: return .managedElsewhere
        case .folder(let hash):
            guard let hash else { return .changedOutsideCai }
            // No bundled skill to compare with (a broken Cai): nothing to offer.
            guard let bundled, hash != bundled else { return .current }
            return hash == lastInstalled ? .updateAvailable : .changedOutsideCai
        }
    }

    /// Like `inspect`, but keeps the installed hash for `status`.
    static func installed(at url: URL, fileManager: FileManager = .default) -> Installed {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return .missing }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return .symlink }
        return .folder(hash: contentHash(of: url, fileManager: fileManager))
    }

    /// `TodayState/skill.json`: the hash of the skill Cai last wrote to the
    /// install path. Without it an old copy and an edited copy look alike.
    static var recordURL: URL { TodayStore.stateFolder.appendingPathComponent("skill.json") }

    /// The hash Cai last installed, only when this build (`bundleID`) wrote
    /// it: Debug and Release share `TodayState/`, and a Release build must
    /// never offer to replace what a Debug build installed, or the reverse.
    static func lastInstalled(record: URL = recordURL, bundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        guard let data = try? Data(contentsOf: record),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["v"] as? Int == 1, let bundleID, object["by"] as? String == bundleID else { return nil }
        return object["installed"] as? String
    }

    static func recordInstalled(_ hash: String?, record: URL = recordURL, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let hash, let bundleID,
              let data = try? JSONSerialization.data(withJSONObject: ["v": 1, "installed": hash, "by": bundleID], options: .sortedKeys) else { return }
        try? FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: record, options: .atomic)
    }

    /// The skills folder or `~/.claude` when either is a link, else nil. Cai
    /// doesn't write through a link it doesn't manage; the user copies the
    /// skill there themselves.
    static func linkedParent(of installed: URL, levels: Int = 2, fileManager: FileManager = .default) -> URL? {
        var folder = installed.deletingLastPathComponent()
        for _ in 0..<levels {
            if (try? fileManager.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeSymbolicLink { return folder }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// Thrown instead of writing through a linked skills folder.
    struct LinkedFolder: Error, Equatable {
        let folder: URL
        let copyFrom: URL
        var message: String { "Your skills folder is a link; add the skill there yourself. Copy it from \(copyFrom.path)" }
    }

    /// Checks again at click time (the folder may have changed since Settings
    /// drew the button), then swaps in a fresh copy of the bundled skill and
    /// records its hash. Returns the status it acted on: anything but
    /// `.updateAvailable` means nothing was written.
    @discardableResult
    static func updateIfSafe(bundled: URL, to installed: URL, record: URL = recordURL,
                             bundleID: String? = Bundle.main.bundleIdentifier, fileManager: FileManager = .default) throws -> Status {
        let bundledHash = contentHash(of: bundled, fileManager: fileManager)
        let found = status(installed: Self.installed(at: installed, fileManager: fileManager),
                           bundled: bundledHash, lastInstalled: lastInstalled(record: record, bundleID: bundleID))
        guard found == .updateAvailable else { return found }
        if let folder = linkedParent(of: installed, fileManager: fileManager) {
            throw LinkedFolder(folder: folder, copyFrom: bundled)
        }
        let staging = installed.deletingLastPathComponent()
            .appendingPathComponent(".cai-today-update-\(UUID().uuidString)")
        try fileManager.copyItem(at: bundled, to: staging)
        do {
            _ = try fileManager.replaceItemAt(installed, withItemAt: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        recordInstalled(bundledHash, record: record, bundleID: bundleID)
        return found
    }

    /// SHA-256 over everything under `folder`, in path order: each entry's
    /// relative path and type, then a file's size and contents, a link's
    /// target path (not followed), or nothing for a folder. So adding a link
    /// or an empty folder changes the hash. `.DS_Store` is skipped (Finder
    /// writes it on open). Nil when `folder` isn't a readable directory.
    static func contentHash(of folder: URL, fileManager: FileManager = .default) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let walker = fileManager.enumerator(atPath: folder.path) else { return nil }
        var paths: [String] = []
        while let path = walker.nextObject() as? String {
            if (path as NSString).lastPathComponent != ".DS_Store" { paths.append(path) }
        }
        var hasher = SHA256()
        func add(_ text: String) {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0]))
        }
        for path in paths.sorted() {
            let full = folder.appendingPathComponent(path).path
            guard let type = (try? fileManager.attributesOfItem(atPath: full))?[.type] as? FileAttributeType else { return nil }
            add(path)
            switch type {
            case .typeRegular:
                guard let data = fileManager.contents(atPath: full) else { return nil }
                add("file")
                add(String(data.count))
                hasher.update(data: data)
            case .typeSymbolicLink:
                add("link")
                add((try? fileManager.destinationOfSymbolicLink(atPath: full)) ?? "")
            case .typeDirectory:
                add("folder")
            default:
                add("other")
            }
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

    /// What a new `priorities.md` starts from: the bundled template, else the
    /// fallback. Setup's save and Settings' "Open in Finder" both use it.
    static var starter: String {
        TodaySkill.bundledURL.flatMap { try? String(contentsOf: $0.appendingPathComponent("priorities.template.md"), encoding: .utf8) }
            ?? fallbackTemplate
    }

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
    /// right after the section's leading comment lines. A line that is part
    /// of a `<!-- … -->` comment, on one line or many, is never a header,
    /// never removed and never split by an insertion.
    static func render(_ entries: [TodayPriorityEntry], into base: String) -> String {
        var lines = base.components(separatedBy: "\n")
        for (header, kind) in [(peopleHeader, TodayPriorityEntry.Kind.person), (channelsHeader, .channel)] {
            let wanted = entries.filter { $0.kind == kind }.compactMap(line(for:))
            let comment = commentMask(lines)
            guard let start = lines.indices.first(where: { !comment[$0] && lines[$0].trimmingCharacters(in: .whitespaces) == header }) else {
                if !wanted.isEmpty { lines += ["", header] + wanted }
                continue
            }
            var end = start + 1
            while end < lines.count, comment[end] || !lines[end].hasPrefix("#") { end += 1 }
            var insertAt = start + 1
            while insertAt < end, comment[insertAt] { insertAt += 1 }
            var body = ((start + 1)..<end).filter { comment[$0] || !isEntry(lines[$0]) }.map { lines[$0] }
            // The leading comment lines are all kept, so this lands right after them.
            body.insert(contentsOf: wanted, at: insertAt - (start + 1))
            lines.replaceSubrange((start + 1)..<end, with: body)
        }
        return lines.joined(separator: "\n")
    }

    /// Which lines touch a `<!-- … -->` comment: inside one, or opening or
    /// closing one.
    static func commentMask(_ lines: [String]) -> [Bool] {
        var open = false
        return lines.map { line in
            var touched = open
            var rest = Substring(line)
            while true {
                if open {
                    guard let close = rest.range(of: "-->") else { break }
                    open = false
                    rest = rest[close.upperBound...]
                } else {
                    guard let start = rest.range(of: "<!--") else { break }
                    open = true
                    touched = true
                    rest = rest[start.upperBound...]
                }
            }
            return touched || open
        }
    }

    /// Step 4's list merged with the file as it is at save time. Entries the
    /// user added to the file by hand while step 4 was open are kept; an
    /// entry is dropped only when it was in the list step 4 started from
    /// (`started`) and the user removed it there.
    static func merge(_ entries: [TodayPriorityEntry], started: [TodayPriorityEntry], onDisk: [TodayPriorityEntry]) -> [TodayPriorityEntry] {
        func key(_ entry: TodayPriorityEntry) -> String {
            var plain = entry
            plain.starred = false
            return "\(entry.kind)|" + fold(line(for: plain) ?? entry.name)
        }
        let known = Set((entries + started).map(key))
        var kept = Set<String>()
        let added = onDisk.filter { !known.contains(key($0)) && kept.insert(key($0)).inserted }
        return entries + added
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
