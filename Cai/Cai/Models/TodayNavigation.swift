import AppKit
import HotKey

/// What a ⌘ shortcut does on the Today screen. Plain keys (↑↓←→, ↵, Esc, typing) keep their
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
    /// ⌘R: rebuild the list (`TodayRunner`).
    case refresh
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
    /// On in Release from 1.7.1: Cai installs and runs the skill itself now
    /// (setup and the runner). 1.7.0 shipped with this still Debug-only.
    /// Kept as one switch so Today can be hidden again in a single line.
    static let isEnabled = true

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
        case 15: return .refresh       // R
        default: return nil
        }
    }

    /// An arrow key in details. `index` is the item's place among the
    /// list's items, `count` how many there are.
    enum DetailArrow: Equatable { case up, down, left, right }

    enum DetailMove: Equatable {
        /// Show the item at this index.
        case item(Int)
        /// Back to the list, the same item selected.
        case list
        /// At the first or last item, or a key details doesn't use.
        case stay
    }

    /// In details, ↑↓ go to the previous and next item without wrapping (the
    /// "1 of 5" hint keeps its meaning), ← goes back to the list, and → does
    /// nothing (it already opened details).
    static func detailMove(_ arrow: DetailArrow, index: Int, count: Int) -> DetailMove {
        switch arrow {
        case .left: return .list
        case .right: return .stay
        case .up: return index > 0 && index < count ? .item(index - 1) : .stay
        case .down: return index >= 0 && index + 1 < count ? .item(index + 1) : .stay
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

/// The optional global shortcut that opens Cai on Today (Settings → Today).
enum TodayShortcut {
    enum Problem: Equatable {
        /// The same combo as Cai's own shortcut: one of the two would never fire.
        case sameAsMain
        /// No ⌘, ⌥ or ⌃: it would take that key away from typing in every app.
        case noModifier
    }

    /// Why a recorded combo can't be the Today shortcut, or nil when it can.
    static func problem(with combo: KeyCombo, main: KeyCombo) -> Problem? {
        if combo == main { return .sameAsMain }
        if combo.modifiers.intersection([.command, .option, .control]).isEmpty { return .noModifier }
        return nil
    }

    /// What to register, or nil. Checked again at registration, so changing
    /// Cai's own shortcut to the Today one later turns Today's off instead of
    /// registering the same combo twice.
    static func registered(today: KeyCombo?, main: KeyCombo) -> KeyCombo? {
        guard let today, problem(with: today, main: main) == nil else { return nil }
        return today
    }

    /// The one line under the recorder, whatever the combo.
    static let note = "Works in every app, so it replaces what these keys do there."

    static func message(_ problem: Problem) -> String {
        switch problem {
        case .sameAsMain: return "That's Cai's own shortcut. Pick another."
        case .noModifier: return "Add ⌘, ⌥ or ⌃ to the shortcut."
        }
    }
}
