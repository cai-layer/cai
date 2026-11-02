import CaiActionCore
import Foundation

/// One entry of the Today list, as the `cai-today` skill writes it
/// (`skills/cai-today/reference/format.md`).
///
/// Every field comes from email, chat and issue text, so the file is treated as
/// untrusted: `TodayFile.item(fromLine:)` is the only way to build one, and it
/// refuses a line rather than repair it when the line could mislead the user
/// (a non-https link, a prompt over the cap). Display fields are cleaned of
/// control and bidi characters, because a title carrying U+202E reorders the
/// text around it and can read as something it isn't.
struct TodayItem: Equatable, Identifiable {
    enum Priority: String, CaseIterable, Comparable {
        case p0 = "P0", p1 = "P1", p2 = "P2", p3 = "P3"

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    let id: String
    let url: URL
    let source: String
    let title: String
    let why: String
    let who: String
    let priority: Priority
    let created: Date
    let activity: Date
    /// Shown verbatim in details and copied verbatim: what the user reads is
    /// exactly what lands in their agent.
    let prompt: String
    /// The main link first. Kept as text: only `isOpenable` links may be opened.
    let links: [String]

    /// The one rule for what Cai may hand to `NSWorkspace.open`.
    static func isOpenable(_ link: String) -> Bool {
        guard let url = URL(string: link), url.scheme?.lowercased() == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }
}

/// The header line: when the list was built and which sources were read.
struct TodayHeader: Equatable {
    struct Source: Equatable {
        let name: String
        let read: Bool
        let reason: String?
    }

    let generated: Date
    let sources: [Source]
}

enum TodayFile {
    static let version = 1

    static let maxId = 200
    static let maxTitle = 120
    static let maxWhy = 200
    static let maxWho = 120
    static let maxPrompt = 2000
    static let maxLinks = 10

    struct Parsed: Equatable {
        /// Nil when the first line is not a version-1 header: then no item is shown.
        let header: TodayHeader?
        let items: [TodayItem]
        /// Lines that were refused, for the "items not shown" line.
        let notShown: Int
    }

    /// Reads a whole `items.jsonl`. A file whose header is missing or carries
    /// another version shows nothing: its items may mean something else.
    /// Two lines with the same `url` are one subject: the first one wins, and
    /// the repeat is not counted as refused, since nothing was lost.
    static func parse(_ text: String) -> Parsed {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first, let header = header(fromLine: first) else {
            return Parsed(header: nil, items: [], notShown: max(lines.count - 1, 0))
        }
        var items: [TodayItem] = []
        var seen = Set<String>()
        var refused = 0
        for line in lines.dropFirst() {
            guard let item = item(fromLine: line) else {
                refused += 1
                continue
            }
            if seen.insert(item.url.absoluteString).inserted { items.append(item) }
        }
        return Parsed(header: header, items: items, notShown: refused)
    }

    static func header(fromLine line: String) -> TodayHeader? {
        guard let object = jsonObject(line),
              object["type"] as? String == "header",
              object["v"] as? Int == version,
              let generated = (object["generated"] as? String).flatMap(date) else { return nil }
        let sources = (object["sources"] as? [[String: Any]] ?? []).compactMap { entry -> TodayHeader.Source? in
            guard let name = entry["name"] as? String else { return nil }
            return TodayHeader.Source(
                name: clean(name),
                read: entry["status"] as? String == "read",
                reason: (entry["reason"] as? String).map(clean)
            )
        }
        return TodayHeader(generated: generated, sources: sources)
    }

    static func item(fromLine line: String) -> TodayItem? {
        guard let object = jsonObject(line),
              let id = object["id"] as? String, !id.isEmpty, id.count <= maxId,
              let urlText = object["url"] as? String, TodayItem.isOpenable(urlText),
              let url = URL(string: urlText),
              let source = object["source"] as? String,
              let title = object["title"] as? String,
              let why = object["why"] as? String,
              let priority = (object["priority"] as? String).flatMap(TodayItem.Priority.init(rawValue:)),
              let created = (object["created"] as? String).flatMap(date),
              let activity = (object["activity"] as? String).flatMap(date),
              let prompt = object["prompt"] as? String, prompt.count <= maxPrompt,
              let links = object["links"] as? [String], links.count <= maxLinks
        else { return nil }
        let cleanTitle = clean(title)
        guard !cleanTitle.isEmpty else { return nil }
        return TodayItem(
            id: id,
            url: url,
            source: clean(source).lowercased(),
            title: capped(cleanTitle, maxTitle),
            why: capped(clean(why), maxWhy),
            who: capped(clean(object["who"] as? String ?? ""), maxWho),
            priority: priority,
            created: created,
            activity: activity,
            prompt: prompt.strippingControlCharacters(keepingNewlines: true),
            links: links.isEmpty ? [urlText] : links
        )
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func clean(_ value: String) -> String {
        value.strippingControlCharacters(keepingNewlines: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capped(_ value: String, _ limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit - 1)) + "…"
    }

    private static let plainDates = ISO8601DateFormatter()
    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ text: String) -> Date? {
        plainDates.date(from: text) ?? fractionalDates.date(from: text)
    }
}

/// What the user did with each item, kept by Cai in `state.json`, keyed on the
/// item's `url` so it survives a rebuild of the list.
struct TodayState: Codable, Equatable {
    struct Entry: Codable, Equatable {
        enum Kind: String, Codable { case done, dismissed, snoozed }
        let kind: Kind
        /// The item's `activity` when the user acted. Newer activity in the
        /// source brings the item back: a thread marked done on Monday returns
        /// with Tuesday's replies.
        let activity: Date
        /// Snoozed items only.
        let until: Date?
    }

    enum Visibility: Equatable { case shown, snoozed, hidden }

    var v = 1
    var entries: [String: Entry] = [:]

    func visibility(of item: TodayItem, now: Date) -> Visibility {
        guard let entry = entries[item.url.absoluteString], item.activity <= entry.activity else { return .shown }
        switch entry.kind {
        case .done, .dismissed: return .hidden
        case .snoozed: return (entry.until ?? .distantPast) > now ? .snoozed : .shown
        }
    }

    /// Done, dismiss and snooze are values: undo is restoring the state from
    /// before the change, so there is no inverse to get wrong.
    func marking(_ item: TodayItem, _ kind: Entry.Kind, now: Date, calendar: Calendar = .current) -> TodayState {
        var next = self
        let until = kind == .snoozed ? Self.snoozeEnd(after: now, calendar: calendar) : nil
        next.entries[item.url.absoluteString] = Entry(kind: kind, activity: item.activity, until: until)
        return next
    }

    func clearing(_ item: TodayItem) -> TodayState {
        var next = self
        next.entries[item.url.absoluteString] = nil
        return next
    }

    /// Snooze has one setting: tomorrow at 09:00, local time.
    static func snoozeEnd(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }
}

/// How the Today screen orders and groups the list.
enum TodayList {
    struct Sections: Equatable {
        /// P0 and P1.
        var now: [TodayItem] = []
        /// P2 and P3, collapsed under "Later".
        var later: [TodayItem] = []
        var snoozed: [TodayItem] = []
    }

    /// Priority first; within a priority, the oldest first, since it has
    /// waited longest.
    static func ordered(_ items: [TodayItem]) -> [TodayItem] {
        items.sorted { ($0.priority, $0.created, $0.id) < ($1.priority, $1.created, $1.id) }
    }

    static func sections(_ items: [TodayItem], state: TodayState, now: Date) -> Sections {
        var sections = Sections()
        for item in ordered(items) {
            switch state.visibility(of: item, now: now) {
            case .hidden: continue
            case .snoozed: sections.snoozed.append(item)
            case .shown:
                if item.priority <= .p1 { sections.now.append(item) } else { sections.later.append(item) }
            }
        }
        return sections
    }

    /// Typing searches every group at once, as one flat list: shown items by
    /// priority, then snoozed ones. A word in the title, the person or the
    /// source must start with the query, the action list's matching rule.
    static func filtered(_ items: [TodayItem], state: TodayState, query: String, now: Date) -> [TodayItem] {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let all = sections(items, state: state, now: now)
        return (all.now + all.later + all.snoozed).filter { item in
            "\(item.title) \(item.who) \(item.source)".lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "#" || $0 == "@" })
                .contains { $0.hasPrefix(query) }
        }
    }
}
