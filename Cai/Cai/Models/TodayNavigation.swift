import AppKit

/// What a ⌘ shortcut does on the Today screen (the round-2 key scheme in the
/// Today prototype notes). Plain keys (↑↓←→, ↵, Esc, typing) keep their
/// existing notifications; only these need a branch of their own.
enum TodayCommand: String {
    /// ⌘↵: the same as ↵, copy the prompt and close Cai.
    case copyAndClose
    /// ⌘C: copy the prompt and keep Cai open.
    case copy
    /// ⌘O: open the first link, then close.
    case open
    /// ⌘D
    case done
    /// ⌘⌫
    case dismiss
    /// ⌘S: snooze, or unsnooze a snoozed item.
    case snooze
    /// ⌘Z: undo the last done, dismiss or snooze.
    case undo
}

/// One line of the Today list: an item, or a collapsible group header.
enum TodayRow: Equatable, Identifiable {
    enum Group: String { case later, snoozed }

    case item(TodayItem)
    case group(Group, count: Int, open: Bool)

    /// Keyed on the item's url, which `TodayFile.parse` keeps unique; the
    /// item's own `id` comes from the file and is not checked for clashes.
    var id: String {
        switch self {
        case .item(let item): return item.url.absoluteString
        case .group(let group, _, _): return "group:\(group.rawValue)"
        }
    }

    var item: TodayItem? {
        if case .item(let item) = self { return item }
        return nil
    }
}

enum TodayNavigation {
    /// Today stays in Debug builds until Cai can install and run the skill
    /// itself (setup and the runner, later PRs). A release before that would
    /// show every user a screen that only says to run a command they can't.
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    /// Which Today command a keypress is, or nil to let it fall through.
    ///
    /// Only an exact ⌘ chord counts: ⌘⇧Z is redo and ⌘⌥D is not done. The
    /// check runs ahead of type-to-filter, so ⌘⌫ dismisses while a plain ⌫
    /// still edits the filter. Nil whenever Today is not the active screen, so
    /// ⌘C keeps copying selected text everywhere else.
    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, todayActive: Bool) -> TodayCommand? {
        guard todayActive,
              modifiers.intersection([.command, .shift, .option, .control]) == .command else { return nil }
        switch keyCode {
        case 36: return .copyAndClose  // Return
        case 8: return .copy           // C
        case 31: return .open          // O
        case 2: return .done           // D
        case 51: return .dismiss       // Backspace
        case 1: return .snooze         // S
        case 6: return .undo           // Z
        default: return nil
        }
    }

    /// The unfiltered list: P0 and P1 first, then the Later and Snoozed group
    /// rows, each followed by its items only while open. An empty group gets
    /// no row.
    static func rows(_ sections: TodayList.Sections, laterOpen: Bool, snoozedOpen: Bool) -> [TodayRow] {
        var rows = sections.now.map(TodayRow.item)
        if !sections.later.isEmpty {
            rows.append(.group(.later, count: sections.later.count, open: laterOpen))
            if laterOpen { rows += sections.later.map(TodayRow.item) }
        }
        if !sections.snoozed.isEmpty {
            rows.append(.group(.snoozed, count: sections.snoozed.count, open: snoozedOpen))
            if snoozedOpen { rows += sections.snoozed.map(TodayRow.item) }
        }
        return rows
    }

    /// Where details go after done, dismiss or snooze takes `url` out of
    /// `items`: the next item, else the previous one, else nil (back to the
    /// list). Mail does the same, which is what makes ←→ a way to work
    /// through the list.
    static func neighbour(of url: URL, in items: [TodayItem]) -> TodayItem? {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return nil }
        if index + 1 < items.count { return items[index + 1] }
        return index > 0 ? items[index - 1] : nil
    }
}
