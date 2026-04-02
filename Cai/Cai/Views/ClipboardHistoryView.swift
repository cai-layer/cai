import SwiftUI

/// Submenu showing clipboard history with pinning and type-to-filter search.
/// Triggered by Cmd+0. Pinned items stick to the top and persist across relaunches.
/// Type to search, ⌘1-9 to quick-copy, star to pin/unpin.
struct ClipboardHistoryView: View {
    @ObservedObject var history = ClipboardHistory.shared
    @ObservedObject var selectionState: SelectionState
    let onSelect: (ClipboardHistory.Entry) -> Void
    let onBack: () -> Void

    /// Tracks which entry is hovered for progressive pin button disclosure
    @State private var hoveredEntryID: UUID?

    /// Filtered entries: pinned first, then regular. Substring search on full text.
    private var displayedEntries: [ClipboardHistory.Entry] {
        let all = history.allEntries
        guard !selectionState.filterText.isEmpty else { return all }
        let query = selectionState.filterText.lowercased()
        return all.filter { $0.text.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.caiPrimary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Clipboard History")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.caiTextPrimary)

                    Text(headerSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Filter bar (shown when typing)
            if !selectionState.filterText.isEmpty {
                filterBarView
            }

            Divider()
                .background(Color.caiDivider)

            // History list
            let visible = displayedEntries
            if visible.isEmpty && history.allEntries.isEmpty {
                emptyStateView
            } else if visible.isEmpty {
                noMatchesView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                                historyRow(entry: entry, displayIndex: index, isSelected: index == selectionState.selectedIndex)
                                    .id(entry.id)
                                    .onTapGesture {
                                        selectionState.selectedIndex = index
                                        onSelect(entry)
                                    }
                                    .onHover { hovering in
                                        hoveredEntryID = hovering ? entry.id : nil
                                    }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                    }
                    .onChange(of: selectionState.selectedIndex) { newValue in
                        if newValue < visible.count {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(visible[newValue].id, anchor: .center)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack(spacing: 12) {
                KeyboardHint(key: "↑↓", label: "Navigate")
                KeyboardHint(key: "↵", label: "Copy")
                KeyboardHint(key: "Esc", label: selectionState.filterText.isEmpty ? "Back" : "Clear")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        // Clamp selection when entries change (pin/unpin/new entry)
        .onChange(of: history.pinnedEntries.count) { _ in clampSelection() }
        .onChange(of: history.regularEntries.count) { _ in clampSelection() }
    }

    // MARK: - Header Subtitle

    private var headerSubtitle: String {
        let pinned = history.pinnedEntries.count
        let regular = history.regularEntries.count
        if pinned > 0 {
            return "\(pinned) pinned, \(regular) recent"
        } else {
            return "\(regular) copied item\(regular == 1 ? "" : "s")"
        }
    }

    // MARK: - Filter Bar

    private var filterBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary.opacity(0.6))

            Text(selectionState.filterText)
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

    // MARK: - Empty States

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clipboard")
                .font(.system(size: 28))
                .foregroundColor(.caiTextSecondary.opacity(0.4))
            Text("No clipboard history yet")
                .font(.system(size: 13))
                .foregroundColor(.caiTextSecondary)
            Text("Copy some text to get started")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }

    private var noMatchesView: some View {
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

    // MARK: - History Row

    private func historyRow(entry: ClipboardHistory.Entry, displayIndex: Int, isSelected: Bool) -> some View {
        let isHovered = hoveredEntryID == entry.id
        let canPin = entry.isPinned || history.pinnedEntries.count < ClipboardHistory.maxPinnedEntries
        // Show pin icon when: pinned (always), or hovered/selected AND there's room to pin
        let showPinIcon = entry.isPinned || ((isHovered || isSelected) && canPin)

        return HStack(spacing: 12) {
            // Icon — doubles as pin toggle on hover/selection (progressive disclosure)
            Button(action: {
                if entry.isPinned {
                    history.unpinEntry(entry)
                } else if canPin {
                    history.pinEntry(entry)
                }
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(entry.isPinned
                              ? Color.caiPrimary.opacity(0.15)
                              : isSelected
                                ? Color.caiPrimary.opacity(0.15)
                                : Color.caiSurface.opacity(0.6))
                        .frame(width: 28, height: 28)

                    if showPinIcon {
                        Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(entry.isPinned ? .caiPrimary : .caiTextSecondary.opacity(0.5))
                    } else {
                        Image(systemName: entry.isImage ? "photo" : "doc.on.clipboard")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.caiTextSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(entry.isPinned ? "Unpin" : "Pin to top")

            // Preview text
            Text(entry.preview)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.caiTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Shortcut badge (re-numbered by display position)
            if displayIndex < 9 {
                HStack(spacing: 2) {
                    Text("\u{2318}")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(displayIndex + 1)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.caiSurface.opacity(0.5))
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.caiPrimarySubtle : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.isPinned ? "Pinned " : "")Clipboard entry \(displayIndex + 1): \(entry.preview)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Helpers

    private func clampSelection() {
        let count = displayedEntries.count
        if selectionState.selectedIndex >= count {
            selectionState.selectedIndex = max(0, count - 1)
        }
    }
}
