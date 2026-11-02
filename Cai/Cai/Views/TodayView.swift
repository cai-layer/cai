import SwiftUI

/// Where the Today screen is: selection, filter, open groups, details. Owned
/// by `ActionListWindow`, which routes the panel's keys here; the view's own
/// clicks call the same methods, so a key and a click can't drift apart.
@MainActor
final class TodayScreenState: ObservableObject {
    @Published var selectedIndex = 0
    @Published var filterText = ""
    @Published var laterOpen = false
    @Published var snoozedOpen = false
    /// The item details are showing, by url. Nil, or an item that has left the
    /// list, means the list.
    @Published var detailURL: URL?
    /// Opened from the menu bar: there is no selection to go back to, so Esc
    /// closes Cai instead.
    @Published var fromMenu = false

    /// What the empty state offers when `claude` isn't found.
    static let skillCommand = #"claude -p "/cai-today""#

    private var store: TodayStore { .shared }
    private var runner: TodayRunner { .shared }
    private var setup: TodaySetup { .shared }

    /// The setup step on screen, if any. The intro gives way to the old
    /// "run this command" state when Cai can't find `claude`.
    var setupStep: TodaySetup.Step? {
        guard let step = setup.step else { return nil }
        return step == .intro && runner.claudeFound == false ? nil : step
    }

    func reset(fromMenu: Bool) {
        selectedIndex = 0
        filterText = ""
        laterOpen = false
        snoozedOpen = false
        detailURL = nil
        self.fromMenu = fromMenu
        // Undo belongs to this visit: ⌘Z tomorrow must not bring back
        // something dismissed this morning.
        store.clearUndo()
        store.open()
        setup.resume(listMissing: store.list == .noFile)
        runner.lookUpClaude()
        if case .loaded(let parsed) = store.list {
            runner.refreshIfStale(generated: parsed.header?.generated)
        }
    }

    func rows(now: Date = Date()) -> [TodayRow] {
        let items = store.items
        if !filterText.isEmpty {
            return TodayList.filtered(items, state: store.state, query: filterText, now: now).map(TodayRow.item)
        }
        return TodayNavigation.rows(
            TodayList.sections(items, state: store.state, now: now),
            laterOpen: laterOpen, snoozedOpen: snoozedOpen
        )
    }

    var detailItem: TodayItem? {
        guard let url = detailURL else { return nil }
        return store.items.first { $0.url == url }
    }

    /// The item ↵ and the ⌘ keys act on.
    var current: TodayItem? {
        if let detailItem { return detailItem }
        let rows = rows()
        return rows.indices.contains(selectedIndex) ? rows[selectedIndex].item : nil
    }

    /// No list yet, or one this build can't read: ↵ builds one when `claude`
    /// was found, else copies the skill command.
    var needsSkillRun: Bool {
        switch store.list {
        case .noFile: return true
        case .loaded(let parsed): return parsed.header == nil
        }
    }

    func isSnoozed(_ item: TodayItem) -> Bool {
        store.state.visibility(of: item, now: Date()) == .snoozed
    }

    // MARK: - Keys and clicks

    /// ↑↓ wrap in the list, as on the action list and in History. In
    /// details they go to the previous and next item, without wrapping.
    func move(by delta: Int) {
        if setupStep != nil { return setup.move(by: delta) }
        if detailItem != nil { return detail(delta < 0 ? .up : .down) }
        let count = rows().count
        guard count > 0 else { return }
        let from = min(selectedIndex, count - 1)
        selectedIndex = ((from + delta) % count + count) % count
    }

    func enter(close: @escaping () -> Void) {
        if setupStep != nil { return setup.enter() }
        if needsSkillRun {
            if runner.claudeFound == true {
                runner.start()
            } else {
                SystemActions.copyToClipboard(Self.skillCommand)
                ToastQueue.post("Copied to Clipboard", outcome: .success)
            }
            return
        }
        if detailItem == nil, let row = rows()[safe: selectedIndex], case .group(let group, _, _) = row {
            toggle(group)
            return
        }
        perform(.copyAndClose, close: close)
    }

    /// → opens details or a closed group; ← closes an open group. In
    /// details, ← goes back to the list with the same item selected.
    func arrow(_ delta: Int) {
        if setupStep != nil { return }
        if detailItem != nil { return detail(delta < 0 ? .left : .right) }
        guard let row = rows()[safe: selectedIndex] else { return }
        switch row {
        case .group(let group, _, let open):
            if (delta > 0) != open { toggle(group) }
        case .item(let item):
            if delta > 0 { openDetail(item) }
        }
    }

    func esc(close: () -> Void, back: () -> Void) {
        if setupStep != nil {
            if setup.esc() { return }
            return fromMenu ? close() : back()
        }
        if detailItem != nil {
            detailURL = nil
            return
        }
        detailURL = nil
        if !filterText.isEmpty {
            filterText = ""
            selectedIndex = 0
        } else if fromMenu {
            close()
        } else {
            back()
        }
    }

    func type(_ character: String) {
        if setupStep != nil { return setup.type(character) }
        guard detailItem == nil, !store.items.isEmpty else { return }
        filterText.append(character)
        selectedIndex = 0
    }

    func backspace() {
        if setupStep != nil { return setup.backspace() }
        guard detailItem == nil, !filterText.isEmpty else { return }
        filterText.removeLast()
        selectedIndex = 0
    }

    func toggle(_ group: TodayRow.Group) {
        withAnimation(.easeOut(duration: 0.15)) {
            switch group {
            case .later: laterOpen.toggle()
            case .snoozed: snoozedOpen.toggle()
            }
        }
    }

    func openDetail(_ item: TodayItem) {
        select(item)
        withAnimation(.easeOut(duration: 0.2)) { detailURL = item.url }
    }

    func select(_ item: TodayItem) {
        if let index = rows().firstIndex(where: { $0.item?.url == item.url }) { selectedIndex = index }
    }

    func perform(_ command: TodayCommand, close: @escaping () -> Void) {
        if setupStep != nil { return setup.command(command) }
        if command == .refresh {
            runner.start()
            return
        }
        if command == .undo {
            if store.undo() {
                clampSelection()
                ToastQueue.post("Restored", outcome: .success)
            }
            return
        }
        guard let item = current else { return }
        switch command {
        case .copyAndClose:
            copy(item)
            // Close first, as History does, so the toast doesn't land on the panel.
            close()
            ToastQueue.post("Prompt copied → paste into your agent", outcome: .success)
        case .copy:
            copy(item)
            ToastQueue.post("Prompt copied → paste into your agent", outcome: .success)
        case .open:
            open(item.links.first ?? "", of: item, close: close)
        case .done:
            remove(item, .done, toast: "Marked done → ⌘Z to undo")
        case .dismiss:
            remove(item, .dismissed, toast: "Dismissed → ⌘Z to undo")
        case .snooze:
            if isSnoozed(item) {
                store.unsnooze(item)
                ToastQueue.post("Back in Today", outcome: .success)
            } else {
                remove(item, .snoozed, toast: "Snoozed until tomorrow → ⌘Z to undo")
            }
        case .undo, .refresh:
            break
        }
    }

    /// Only `TodayItem.isOpenable` links reach `NSWorkspace`.
    func open(_ link: String, of item: TodayItem, close: () -> Void) {
        guard TodayItem.isOpenable(link), let url = URL(string: link) else {
            ToastQueue.post("Not opened: not an https link", outcome: .problem)
            return
        }
        NSWorkspace.shared.open(url)
        store.log("open", url: item.url)
        close()
    }

    private func copy(_ item: TodayItem) {
        SystemActions.copyToClipboard(item.prompt)
        store.log("copy", url: item.url)
    }

    private func detail(_ arrow: TodayNavigation.DetailArrow) {
        guard let url = detailURL else { return }
        let items = rows().compactMap(\.item)
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        switch TodayNavigation.detailMove(arrow, index: index, count: items.count) {
        case .item(let next):
            detailURL = items[next].url
            select(items[next])
        case .list:
            // `select` already follows details, so the list opens on this item.
            select(items[index])
            withAnimation(.easeOut(duration: 0.2)) { detailURL = nil }
        case .stay:
            break
        }
    }

    /// From details, done, dismiss and snooze move on to the next item, and
    /// back to the list when none is left. In the list, the next row slides
    /// into the selection.
    private func remove(_ item: TodayItem, _ kind: TodayState.Entry.Kind, toast: String) {
        let inDetail = detailItem != nil
        let next = inDetail ? TodayNavigation.neighbour(of: item.url, in: rows().compactMap(\.item)) : nil
        store.mark(item, kind)
        if inDetail {
            detailURL = next?.url
            if let next { select(next) }
        }
        clampSelection()
        ToastQueue.post(toast, outcome: .success)
    }

    private func clampSelection() {
        let count = rows().count
        if selectedIndex >= count { selectedIndex = max(0, count - 1) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - View

struct TodayView: View {
    @ObservedObject var screen: TodayScreenState
    @ObservedObject private var store = TodayStore.shared
    @ObservedObject private var runner = TodayRunner.shared
    @ObservedObject private var setup = TodaySetup.shared
    let onClose: () -> Void

    @State private var hoveredRow: String?
    @State private var hoveringDone = false

    var body: some View {
        if let step = screen.setupStep {
            TodaySetupView(setup: setup, step: step, escLabel: screen.fromMenu ? "Close" : "Back")
        } else if let item = screen.detailItem {
            detailView(item)
        } else {
            listView
        }
    }

    // MARK: List

    private var listView: some View {
        let rows = screen.rows()
        return VStack(spacing: 0) {
            header
            if !screen.filterText.isEmpty { filterBar }
            Divider().background(Color.caiDivider)

            switch store.list {
            case .noFile:
                setupEmptyState(title: "No Today list yet",
                                description: runner.claudeFound == true
                                    ? "Cai builds it with your Claude Code and the cai-today skill, reading your tools without changing anything. It takes a few minutes."
                                    : "Run the cai-today skill in Terminal. The list shows here as soon as it's written.")
            case .loaded(let parsed) where parsed.header == nil:
                setupEmptyState(title: "Can't read this list",
                                description: runner.claudeFound == true
                                    ? "The file isn't in a format this version of Cai reads. Build it again."
                                    : "The file isn't in a format this version of Cai reads. Run the cai-today skill again.")
            case .loaded(let parsed):
                if rows.isEmpty && screen.filterText.isEmpty {
                    allDoneState
                } else if rows.isEmpty {
                    noMatches
                } else {
                    list(rows)
                }
                if parsed.notShown > 0 { notShownLine(parsed.notShown) }
            }

            Spacer(minLength: 0)
            Divider().background(Color.caiDivider)
            listFooter(rows)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Today")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)
                if let subtitle = headerSubtitle {
                    HStack(spacing: 5) {
                        if runner.isRunning { RefreshPulse() }
                        Text(subtitle.text)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(subtitle.failed ? .caiError : .caiTextSecondary)
                    .help(subtitle.help)
                }
            }
            Spacer()
            KeyboardHint(key: "⌘R", label: "Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// "Updated 09:12 · 8 items", plus the sources the skill couldn't read.
    /// While a run goes: "Refreshing… · 8 items". After a failed run, in
    /// orange: "Updated 09:12 · Couldn't refresh", with the reason on hover.
    private var headerSubtitle: (text: String, help: String, failed: Bool)? {
        let failure: String? = { if case .failed(let reason) = runner.phase { return reason } else { return nil } }()
        guard case .loaded(let parsed) = store.list, let header = parsed.header else {
            if runner.isRunning { return ("Refreshing…", "", false) }
            if let failure { return ("Couldn't refresh", failure + ". ⌘R tries again.", true) }
            return nil
        }
        let sections = TodayList.sections(parsed.items, state: store.state, now: Date())
        let count = sections.now.count + sections.later.count
        let items = "\(count) \(count == 1 ? "item" : "items")"
        if runner.isRunning { return ("Refreshing… · \(items)", "", false) }
        if let failure {
            return ("Updated \(Self.updated(header.generated)) · Couldn't refresh", failure + ". ⌘R tries again.", true)
        }
        var text = "Updated \(Self.updated(header.generated)) · \(items)"
        let skipped = header.sources.filter { !$0.read }
        if !skipped.isEmpty {
            text += " · Skipped " + skipped.map(\.name).joined(separator: ", ")
        }
        let help = skipped.map { "\($0.name): \($0.reason ?? "not read")" }.joined(separator: "\n")
        return (text, help, false)
    }

    private func list(_ rows: [TodayRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Group {
                            switch row {
                            case .item(let item):
                                itemRow(item, isSelected: index == screen.selectedIndex)
                                    .onTapGesture { screen.openDetail(item) }
                            case .group(let group, let count, let open):
                                groupRow(group, count: count, open: open, isSelected: index == screen.selectedIndex)
                                    .onTapGesture {
                                        screen.selectedIndex = index
                                        screen.toggle(group)
                                    }
                            }
                        }
                        .id(row.id)
                        .onHover { hoveredRow = $0 ? row.id : (hoveredRow == row.id ? nil : hoveredRow) }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .onChange(of: screen.selectedIndex) { _, index in
                guard rows.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(rows[index].id, anchor: .center) }
            }
        }
    }

    private func itemRow(_ item: TodayItem, isSelected: Bool) -> some View {
        let snoozed = screen.isSnoozed(item)
        let meta = snoozed ? Self.snoozeLabel(store.state.entries[item.url.absoluteString]?.until) : nil
        return HStack(spacing: 10) {
            PriorityChip(priority: item.priority)
            doneButton(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(snoozed ? .caiTextSecondary : .caiTextPrimary)
                    .lineLimit(1)
                Text(item.why)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let meta {
                    Text(meta).lineLimit(1)
                } else {
                    Text(item.who).lineLimit(1).truncationMode(.tail)
                    Text(Self.age(since: item.activity))
                        .monospacedDigit()
                        .frame(minWidth: 22, alignment: .trailing)
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.caiTextSecondary.opacity(0.75))
            .frame(maxWidth: 140, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 42)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.caiPrimarySubtle : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Priority \(item.priority.rawValue), \(item.source), \(item.title), \(item.why), \(meta ?? "\(item.who), \(Self.age(since: item.activity)) ago")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The source logo doubles as the done button on hover, like the pin in
    /// Clipboard History: neutral, never green or indigo (DESIGN.md). ⌘D is
    /// the keyboard path.
    private func doneButton(_ item: TodayItem) -> some View {
        let rowHovered = hoveredRow == item.url.absoluteString
        return Button {
            screen.select(item)
            screen.perform(.done, close: onClose)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowHovered ? Color.caiSurface.opacity(0.6) : Color.clear)
                    .frame(width: 28, height: 28)
                if rowHovered {
                    Image(systemName: hoveringDone ? "checkmark.circle" : "circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(hoveringDone ? .caiTextPrimary : .caiTextSecondary.opacity(0.5))
                } else {
                    TodaySourceLogo(source: item.source)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hoveringDone = $0 }
        .help("Mark done")
        .accessibilityLabel("Mark done")
    }

    private func groupRow(_ group: TodayRow.Group, count: Int, open: Bool, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 10)
            Text(group == .later ? "Later" : "Snoozed").font(.system(size: 11, weight: .semibold))
            Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit()
            Spacer()
        }
        .foregroundColor(.caiTextSecondary)
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.caiPrimarySubtle : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group == .later ? "Later" : "Snoozed"), \(count) items, \(open ? "expanded" : "collapsed")")
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary.opacity(0.6))
            Text(screen.filterText)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.caiTextPrimary)
            Spacer()
            Text("type to filter")
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.caiSurface.opacity(0.4))
    }

    private func notShownLine(_ count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.caiError)
            Text("\(count) \(count == 1 ? "item" : "items") not shown: each needs a title and an https link")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .help("The skill wrote them incomplete. They show up once it writes them in full.")
    }

    // MARK: Empty states

    private func setupEmptyState(title: String, description: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.caiTextSecondary.opacity(0.4))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.caiTextPrimary)
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
            if runner.isRunning {
                HStack(spacing: 6) {
                    RefreshPulse()
                    Text("Building your list. Cai can close; it keeps going.")
                }
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
            } else if runner.claudeFound == true {
                // ↵ Build list sits in the footer, ⌘R Refresh in the header.
                if case .failed(let reason) = runner.phase {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(.caiError)
                }
            } else {
                commandBox
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
    }

    private var commandBox: some View {
        HStack(spacing: 8) {
            Text(TodayScreenState.skillCommand)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.caiTextPrimary)
            CopyIconButton(help: "Copy command") {
                SystemActions.copyToClipboard(TodayScreenState.skillCommand)
                ToastQueue.post("Copied to Clipboard", outcome: .success)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.caiSurface.opacity(0.6)))
    }

    /// Only reached when nothing is snoozed either: snoozed items keep their
    /// group row, so they can always be opened and unsnoozed.
    private var allDoneState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.caiTextSecondary.opacity(0.4))
            Text("Nothing waiting")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.caiTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var noMatches: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(.caiTextSecondary.opacity(0.4))
            Text("No matches")
                .font(.system(size: 13))
                .foregroundColor(.caiTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding()
    }

    // MARK: Details

    private func detailView(_ item: TodayItem) -> some View {
        let items = screen.rows().compactMap(\.item)
        let position = items.firstIndex { $0.url == item.url } ?? 0
        let snoozed = screen.isSnoozed(item)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                TodaySourceLogo(source: item.source)
                    .frame(width: 28, height: 28)
                    .help(item.source.capitalized)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snoozed
                         ? "Snoozed until \(Self.snoozeLabel(store.state.entries[item.url.absoluteString]?.until).lowercased())"
                         : "\(item.who), \(Self.age(since: item.activity)) ago")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.caiTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                PriorityChip(priority: item.priority)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(Color.caiDivider)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailSection("Why") {
                        Text(item.why)
                            .font(.system(size: 13))
                            .foregroundColor(.caiTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    detailSection("Links") {
                        ForEach(Array(item.links.enumerated()), id: \.offset) { _, link in
                            linkRow(link, of: item)
                        }
                    }
                    detailSection("Suggested prompt") {
                        // Verbatim and plain: what the user reads here is
                        // exactly what ↵ copies.
                        ZStack(alignment: .topTrailing) {
                            // Not selectable: Today claims ⌘C for the whole
                            // prompt, so a selection would copy something else
                            // than the user picked.
                            Text(item.prompt)
                                .font(.system(size: 13))
                                .foregroundColor(.caiTextPrimary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 12)
                                .padding(.trailing, 40)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.caiSurface.opacity(0.6)))
                            CopyIconButton(help: "Copy prompt") { screen.perform(.copy, close: onClose) }
                                .padding(6)
                        }
                    }
                }
                .padding(16)
            }

            Spacer(minLength: 0)
            Divider().background(Color.caiDivider)
            footer {
                KeyboardHint(key: "↵", label: "Copy prompt")
                if items.count > 1 {
                    KeyboardHint(key: "↑↓", label: "\(position + 1) of \(items.count)")
                }
                itemHints(item, snoozed: snoozed)
            } trailing: {
                KeyboardHint(key: "Esc", label: "Back")
            }
        }
    }

    private func detailSection<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.caiTextSecondary)
            content()
        }
    }

    private func linkRow(_ link: String, of item: TodayItem) -> some View {
        let url = URL(string: link)
        let openable = TodayItem.isOpenable(link)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary)
            if openable, let url {
                Button(url.host ?? link) { screen.open(link, of: item, close: onClose) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)
                    .help(link)
                Text(url.path + (url.query.map { "?\($0)" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(url?.host ?? link)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Not opened: not an https link")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                    .fixedSize()
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private func listFooter(_ rows: [TodayRow]) -> some View {
        let escLabel = !screen.filterText.isEmpty ? "Clear" : (screen.fromMenu ? "Close" : "Back")
        footer {
            if screen.needsSkillRun {
                if runner.claudeFound != true {
                    KeyboardHint(key: "↵", label: "Copy command")
                } else if !runner.isRunning {
                    KeyboardHint(key: "↵", label: "Build list")
                }
            } else if case .group(_, _, let open)? = rows[safe: screen.selectedIndex] {
                KeyboardHint(key: "↵", label: open ? "Collapse" : "Expand")
            } else if let item = screen.current {
                KeyboardHint(key: "↵", label: "Copy prompt")
                KeyboardHint(key: "→", label: "Details")
                itemHints(item, snoozed: screen.isSnoozed(item))
            }
        } trailing: {
            KeyboardHint(key: "Esc", label: escLabel)
        }
    }

    @ViewBuilder
    private func itemHints(_ item: TodayItem, snoozed: Bool) -> some View {
        if let first = item.links.first, TodayItem.isOpenable(first) {
            KeyboardHint(key: "⌘O", label: "Open")
        }
        KeyboardHint(key: "⌘D", label: "Done")
        KeyboardHint(key: "⌘⌫", label: "Dismiss")
        KeyboardHint(key: "⌘S", label: snoozed ? "Unsnooze" : "Snooze")
    }

    private func footer<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Formatting

    /// "5m", "3h", "2d": how long since the latest activity.
    static func age(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }

    static func updated(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " \(time)"
    }

    static func snoozeLabel(_ until: Date?) -> String {
        guard let until else { return "Snoozed" }
        let time = until.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInTomorrow(until) { return "Tomorrow \(time)" }
        if Calendar.current.isDateInToday(until) { return "Today \(time)" }
        return until.formatted(.dateTime.weekday(.abbreviated)) + " \(time)"
    }
}

// MARK: - Keys

/// The panel notifications Today listens to, split out of `ActionListWindow`'s
/// modifier chain (like `RunResultPagingKeys`) to keep it type-checkable.
struct TodayKeys: ViewModifier {
    /// ⌘T
    let onShow: () -> Void
    let onCommand: (TodayCommand) -> Void
    /// -1 for ←, +1 for →.
    let onArrow: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .caiShowToday)) { _ in onShow() }
            .onReceive(NotificationCenter.default.publisher(for: .caiTodayCommand)) { notification in
                if let raw = notification.userInfo?["command"] as? String, let command = TodayCommand(rawValue: raw) {
                    onCommand(command)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .caiArrowLeft)) { _ in onArrow(-1) }
            .onReceive(NotificationCenter.default.publisher(for: .caiArrowRight)) { _ in onArrow(1) }
    }
}

// MARK: - Pieces

/// P0 to P3 as a fact chip: a borderless capsule, never indigo (DESIGN.md
/// "Chip shape"). P0 is bolder rather than coloured, since orange means warning.
private struct PriorityChip: View {
    let priority: TodayItem.Priority

    var body: some View {
        Text(priority.rawValue)
            .font(.system(size: 10, weight: priority == .p0 ? .bold : .medium, design: .rounded))
            .foregroundColor(priority == .p0 ? .caiTextPrimary : .caiTextSecondary)
            .frame(width: 24, height: 16)
            .background(Capsule().fill(Color.caiSurface))
    }
}

/// The dot beside "Refreshing…": a slow fade, never a spinner (v4 mockup).
private struct RefreshPulse: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.caiTextSecondary)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// The copy icon in a box's top-right corner, Claude's code-block style.
private struct CopyIconButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hovering ? .caiTextPrimary : .caiTextSecondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.caiSurface.opacity(0.8) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Where an item came from. The installed app's icon when there is one, the
/// GitHub and Linear marks Cai already ships, else an SF Symbol. Real brand
/// marks for Gmail, Notion and the rest are a follow-up.
struct TodaySourceLogo: View {
    let source: String

    private static let apps = ["slack": "com.tinyspeck.slackmacgap", "notion": "notion.id"]
    private static let symbols = [
        "slack": "number", "gmail": "envelope", "email": "envelope", "notion": "doc.text",
        "calendar": "calendar", "drive": "folder", "pylon": "lifepreserver",
    ]

    var body: some View {
        switch source {
        case "github":
            GitHubIcon(color: .caiTextPrimary).frame(width: 18, height: 18)
        case "linear":
            LinearIcon(color: .caiTextPrimary).frame(width: 18, height: 18)
        default:
            if let icon = AppIcon.image(forBundleId: Self.apps[source], size: 26) {
                Image(nsImage: icon)
            } else {
                Image(systemName: Self.symbols[source] ?? "tray")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
            }
        }
    }
}
