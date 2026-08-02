import AppKit
import CaiActionCore
import SwiftUI

/// SwiftUI-native chip editor for `[ChainStep]` — supports three step types:
/// Cai actions (named), inline LLM directives, and Apple Shortcuts (named).
///
/// **Design (locked 2026-05-04 evening):**
/// - Notion-style sectioned dropdown: "CAI ACTIONS" / "APPLE SHORTCUTS" /
///   "INLINE LLM STEP" — visible on focus, filters live as the user types.
/// - Distinct chip rendering per step type:
///   - `.action` — `link` SF Symbol, name in regular weight
///   - `.inlineLLM` — `sparkles` SF Symbol, **italic** truncated directive
///   - `.appleShortcut` — actual Shortcuts.app icon, name in regular weight
/// - Keyboard nav: ↑/↓ moves selection through all visible suggestions
///   (skipping section headers), ⏎ picks the highlighted item, Esc closes.
/// - Inline LLM chip: tap to open `InlineLLMEditPopover` for editing the
///   directive. Empty directive on commit → chip auto-removes (matches NSTokenField
///   convention; less friction than blocking save).
/// - Apple Shortcuts list: re-fetched on every focus (no persistent cache).
///   Cheap enough (~50-200ms) and avoids stale-data edge cases when the user
///   creates a new Shortcut and immediately returns to Cai.
///
/// **Visual language:** chips use neutral surface fill — under the
/// "indigo discipline" rule (DESIGN.md), chain-step chips are passive
/// labels ("I am a step"), not outcome-producing affordances ("I will
/// act"), so they don't wear the brand color. `caiSurface.opacity(0.6)`
/// fill, hairline divider border, 5pt corner radius, 11pt medium label.
/// Per-type icon is the only visual difference between step types so the
/// overall chain reads as one rhythm.
///
/// Type name kept as `ChainStepsTokenField` (legacy from the v1.6 NSTokenField
/// experiment) to minimize project churn. Internally it's a pure SwiftUI
/// chip editor.
struct ChainStepsTokenField: View {
    @Binding var steps: [ChainStep]
    /// Names of Cai actions available for autocomplete — user shortcuts +
    /// chainable built-in actions (Summarize, Explain, etc.). Split from
    /// destination names so the dropdown can group + icon them separately.
    let availableActionNames: [String]
    /// Names of output destinations available for autocomplete (built-in +
    /// custom). Both `availableActionNames` and `availableDestinationNames`
    /// resolve to the same `ChainStep.action(name:)` enum case at execute
    /// time — the split is purely an authoring affordance.
    let availableDestinationNames: [String]
    let placeholder: String

    /// Combined set used for resolution checks (chip warning glyph). A name
    /// resolves if it's in either pool — the executor doesn't distinguish.
    private var allResolvableNames: Set<String> {
        Set(availableActionNames).union(availableDestinationNames)
    }
    /// Used by chip rendering to pick the right icon (paperplane for
    /// destinations, link for actions).
    private var destinationNameSet: Set<String> {
        Set(availableDestinationNames)
    }

    @State private var inputText: String = ""
    @State private var appleShortcuts: [String] = []
    @State private var selectedIndex: Int = 0
    /// Index into `steps` of the chip whose inline-LLM popover is open.
    /// nil when no popover is open.
    @State private var editingStepIndex: Int?
    @State private var editingDraftDirective: String = ""
    @FocusState private var fieldIsFocused: Bool

    /// Max height of the suggestions dropdown — beyond this it scrolls
    /// internally (matches Notion's slash-command menu behavior). Sections
    /// are NOT capped per-section; users with 30 Apple Shortcuts can still
    /// see all of them via scrolling.
    private static let dropdownMaxHeight: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            chipRow
            if fieldIsFocused {
                suggestionsDropdown
            }
        }
    }

    // MARK: - Chip row (chips + inline TextField)

    private var chipRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                chip(for: step, at: index)
            }
            inputField
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    fieldIsFocused ? Color.caiPrimary.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: fieldIsFocused ? 1.0 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { fieldIsFocused = true }
        // ONE popover for the whole row — anchored by SwiftUI to where the
        // tap happened. Per-chip popovers were creating N NSPopover instances
        // and the first open was noticeably slow.
        .popover(
            isPresented: Binding(
                get: { editingStepIndex != nil },
                set: { if !$0 { commitLLMEdit() } }
            ),
            arrowEdge: .top
        ) {
            LLMEditPopover(
                directive: $editingDraftDirective,
                onCommit: commitLLMEdit,
                onCancel: cancelLLMEdit
            )
        }
    }

    @ViewBuilder
    private func chip(for step: ChainStep, at index: Int) -> some View {
        switch step {
        case .action(let name):
            // Resolution check: action references whose names aren't in
            // either pool (actions or destinations) won't resolve at execute
            // time. Tint the chip + show a tooltip so the user can fix the
            // chain before running it. Common scenario: imported a community
            // extension whose chain refs an action the user hasn't installed.
            let isUnresolved = !allResolvableNames.contains(name)
            // Distinguish actions from destinations visually. The executor
            // treats both as `.action(name:)`, but visually a destination
            // step is "send the result to X" (paperplane) while an action
            // step is "transform the result via X" (link).
            let isDestination = destinationNameSet.contains(name)
            let icon: String = {
                if isUnresolved { return "exclamationmark.triangle.fill" }
                return isDestination ? "paperplane" : "link"
            }()
            chipShell(isWarning: isUnresolved) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(isUnresolved ? .caiError : .caiTextSecondary)
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                        .lineLimit(1)
                    removeButton(at: index, label: name)
                }
            }
            .help(isUnresolved ? "Not installed locally — chain step won't resolve until you add an action or destination named \"\(name)\"" : "")

        case .inlineLLM(let directive):
            chipShell {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.caiTextSecondary)
                    Text(truncate(directive, max: 30))
                        .font(.system(size: 11, weight: .medium).italic())
                        .foregroundColor(.caiTextPrimary)
                        .lineLimit(1)
                    removeButton(at: index, label: "LLM step")
                }
            }
            .help(directive)
            .onTapGesture {
                editingDraftDirective = directive
                editingStepIndex = index
            }
            // NOTE: popover lives at the parent (chipRow) attached to a
            // single sentinel — anchoring it per-chip would create N
            // NSPopover instances and made the first open noticeably slow.

        case .appleShortcut(let name):
            chipShell {
                HStack(spacing: 4) {
                    Image(nsImage: AppleShortcutsService.appIcon)
                        .resizable()
                        .frame(width: 12, height: 12)
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                        .lineLimit(1)
                    removeButton(at: index, label: name)
                }
            }
        }
    }

    private func chipShell<Content: View>(
        isWarning: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Visible-but-quiet edge: full-opacity `separatorColor` (the
        // standard macOS hairline) on a fully-saturated neutral surface.
        // Goal: chips read as clearly-bounded units against the white
        // text-background of the input field, without shouting (no indigo,
        // no shadow). Stronger than the prior 0.5-opacity treatment per
        // 2026-05-06 design feedback.
        //
        // When `isWarning` is true (chain step references a name that doesn't
        // resolve locally), the fill + border tint to `caiError` so the chip
        // reads as "this needs attention" without changing the chip's shape.
        content()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isWarning ? Color.caiError.opacity(0.08) : Color.caiSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isWarning ? Color.caiError.opacity(0.5) : Color.caiDivider,
                        lineWidth: 0.5
                    )
            )
    }

    private func removeButton(at index: Int, label: String) -> some View {
        Button(action: { remove(at: index) }) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.caiTextSecondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help("Remove \(label)")
    }

    private var inputField: some View {
        TextField(steps.isEmpty ? placeholder : "", text: $inputText)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($fieldIsFocused)
            .frame(minWidth: 100)
            // Reset selection to top whenever the filter changes — otherwise
            // keyboard nav lands on a now-out-of-range index.
            .onChange(of: inputText) { _, _ in selectedIndex = 0 }
            // ↑/↓ navigate the dropdown.
            .onKeyPress(.upArrow) {
                let count = flatVisibleItems.count
                guard count > 0 else { return .ignored }
                selectedIndex = (selectedIndex - 1 + count) % count
                return .handled
            }
            .onKeyPress(.downArrow) {
                let count = flatVisibleItems.count
                guard count > 0 else { return .ignored }
                selectedIndex = (selectedIndex + 1) % count
                return .handled
            }
            // Enter picks the highlighted suggestion (or commits typed text
            // as inline LLM if nothing is selected).
            .onSubmit { pickHighlighted() }
            // Esc closes the dropdown.
            .onKeyPress(.escape) {
                if fieldIsFocused {
                    fieldIsFocused = false
                    return .handled
                }
                return .ignored
            }
            // Backspace at empty field removes the previous chip.
            .onKeyPress(.delete) {
                if inputText.isEmpty && !steps.isEmpty {
                    steps.removeLast()
                    return .handled
                }
                return .ignored
            }
            .onChange(of: fieldIsFocused) { _, isFocused in
                guard isFocused else { return }
                // Re-fetch Apple Shortcuts on every focus per the locked
                // design (no persistent cache). Cheap; avoids stale data.
                Task {
                    appleShortcuts = await AppleShortcutsService.shared.list()
                }
            }
    }

    // MARK: - Suggestions dropdown
    //
    // Internal `ScrollView` so the dropdown scrolls inside its own bounds —
    // long lists (e.g. 30 Apple Shortcuts) don't push the surrounding form
    // down. Matches Notion's slash-command menu pattern.

    private var suggestionsDropdown: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleSections.enumerated()), id: \.offset) { sectionIndex, section in
                    if sectionIndex > 0 {
                        Divider().padding(.vertical, 2)
                    }
                    sectionHeader(section.title)
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        let flatIndex = flatVisibleItems.firstIndex { $0 == item } ?? -1
                        DropdownRow(
                            item: item,
                            isSelected: flatIndex == selectedIndex,
                            onTap: { pick(item) }
                        )
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .frame(maxHeight: Self.dropdownMaxHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundColor(.caiTextSecondary.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Suggestion data model

    /// Anything the user can pick from the dropdown. Cai actions and
    /// destinations are kept as separate cases so the dropdown can render
    /// distinct sections and icons; both produce `.action(name:)` ChainStep
    /// values at pick time (the executor doesn't distinguish them — see
    /// `ChainExecutor.resolve`).
    fileprivate enum DropdownItem: Equatable, Hashable {
        case caiAction(name: String)
        case caiDestination(name: String)
        case appleShortcut(name: String)
        /// "+ Inline LLM step" — directive defaults to whatever's typed.
        case inlineLLM(initialDirective: String)
    }

    fileprivate struct DropdownSection {
        let title: String
        let items: [DropdownItem]
    }

    /// The dropdown's sections in display order, with each section's items
    /// already filtered against `inputText` and the current `steps` list.
    /// Order: Custom step (LLM) → Cai Actions → Cai Destinations → Apple
    /// Shortcuts. Custom is first because adding an LLM transform is the most
    /// common new-step composition; Actions and Destinations next as the two
    /// classes of already-saved building blocks; Apple Shortcuts last because
    /// users typically have many and scroll-to-find them.
    private var visibleSections: [DropdownSection] {
        var sections: [DropdownSection] = []

        sections.append(DropdownSection(
            title: "Custom step",
            items: [.inlineLLM(initialDirective: inputText.trimmingCharacters(in: .whitespaces))]
        ))

        let actions = filteredCaiActions
        if !actions.isEmpty {
            sections.append(DropdownSection(title: "Cai Actions", items: actions))
        }

        let destinations = filteredCaiDestinations
        if !destinations.isEmpty {
            sections.append(DropdownSection(title: "Cai Destinations", items: destinations))
        }

        let shortcuts = filteredAppleShortcuts
        if !shortcuts.isEmpty {
            sections.append(DropdownSection(title: "Apple Shortcuts", items: shortcuts))
        }

        return sections
    }

    /// Flat list of selectable items in display order — used by ↑↓ keyboard
    /// nav (which doesn't care about section boundaries).
    private var flatVisibleItems: [DropdownItem] {
        visibleSections.flatMap { $0.items }
    }

    private var filteredCaiActions: [DropdownItem] {
        let q = inputText.trimmingCharacters(in: .whitespaces).lowercased()
        let alreadyUsed = Set(steps.compactMap { step -> String? in
            if case .action(let name) = step { return name.lowercased() }
            return nil
        })
        return availableActionNames
            .filter { !alreadyUsed.contains($0.lowercased()) }
            .filter { matches($0, query: q) }
            .map { .caiAction(name: $0) }
    }

    private var filteredCaiDestinations: [DropdownItem] {
        let q = inputText.trimmingCharacters(in: .whitespaces).lowercased()
        let alreadyUsed = Set(steps.compactMap { step -> String? in
            if case .action(let name) = step { return name.lowercased() }
            return nil
        })
        return availableDestinationNames
            .filter { !alreadyUsed.contains($0.lowercased()) }
            .filter { matches($0, query: q) }
            .map { .caiDestination(name: $0) }
    }

    private var filteredAppleShortcuts: [DropdownItem] {
        let q = inputText.trimmingCharacters(in: .whitespaces).lowercased()
        let alreadyUsed = Set(steps.compactMap { step -> String? in
            if case .appleShortcut(let name) = step { return name.lowercased() }
            return nil
        })
        return appleShortcuts
            .filter { !alreadyUsed.contains($0.lowercased()) }
            .filter { matches($0, query: q) }
            .map { .appleShortcut(name: $0) }
    }

    /// Word-prefix match — same matcher as the action-list filter
    /// (`anyWordHasPrefix`) so users get familiar matching behavior.
    /// Empty query matches all.
    private func matches(_ name: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let words = name.lowercased().split(separator: " ")
        return words.contains { $0.hasPrefix(query) }
    }

    // MARK: - Pick / commit

    private func pickHighlighted() {
        guard selectedIndex >= 0, selectedIndex < flatVisibleItems.count else {
            // No selection (or empty dropdown) → commit typed text as inline LLM
            // if there's any. Otherwise no-op.
            let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pick(.inlineLLM(initialDirective: trimmed))
            }
            return
        }
        pick(flatVisibleItems[selectedIndex])
    }

    private func pick(_ item: DropdownItem) {
        switch item {
        case .caiAction(let name), .caiDestination(let name):
            // Both produce the same `.action(name:)` ChainStep. The split
            // into separate `DropdownItem` cases is purely an authoring
            // affordance — the executor's `resolve(_:)` figures out the
            // actual target by looking up the name across both pools.
            steps.append(.action(name: name))
            inputText = ""
        case .appleShortcut(let name):
            steps.append(.appleShortcut(name: name))
            inputText = ""
        case .inlineLLM(let initialDirective):
            // Add the chip + open the popover for editing. If user dismisses
            // without typing, the chip auto-removes on dismiss.
            steps.append(.inlineLLM(directive: initialDirective))
            inputText = ""
            editingDraftDirective = initialDirective
            editingStepIndex = steps.count - 1
        }
        selectedIndex = 0
        // Keep focus so the user can immediately add another step.
        fieldIsFocused = true
    }

    private func remove(at index: Int) {
        guard index >= 0, index < steps.count else { return }
        steps.remove(at: index)
    }

    // MARK: - LLM popover lifecycle

    private func commitLLMEdit() {
        guard let index = editingStepIndex, index >= 0, index < steps.count else {
            editingStepIndex = nil
            return
        }
        let trimmed = editingDraftDirective.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Auto-remove empty LLM chips — friction-free.
            steps.remove(at: index)
        } else {
            steps[index] = .inlineLLM(directive: trimmed)
        }
        editingStepIndex = nil
        editingDraftDirective = ""
    }

    private func cancelLLMEdit() {
        // If the chip was just added (empty directive at construction), and
        // the user cancels, remove the chip. If they had a prior non-empty
        // directive (editing existing), preserve it.
        guard let index = editingStepIndex, index >= 0, index < steps.count else {
            editingStepIndex = nil
            editingDraftDirective = ""
            return
        }
        if case .inlineLLM(let existing) = steps[index],
           existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps.remove(at: index)
        }
        editingStepIndex = nil
        editingDraftDirective = ""
    }

    // MARK: - Helpers

    private func truncate(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed.isEmpty ? "(empty)" : trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }
}

// MARK: - Dropdown row (separate view to scope its hover state)

private struct DropdownRow: View {
    let item: ChainStepsTokenField.DropdownItem
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                icon
                    .frame(width: 14, height: 14)
                label
                Spacer(minLength: 0)
                if case .inlineLLM(let directive) = item, !directive.isEmpty {
                    // Show preview of the typed text on the right
                    Text("\u{201C}\(directive)\u{201D}")
                        .font(.system(size: 10).italic())
                        .foregroundColor(.caiTextSecondary.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item {
        case .caiAction:
            // Bolt — Cai's brand mark for "action / transform / do something
            // with the input." Same metaphor as the action-list rows.
            Image(systemName: "bolt")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary)
        case .caiDestination:
            // Paperplane — universal "send / route output somewhere" metaphor.
            // Distinguishes destinations from actions in the dropdown so users
            // can see at a glance which kind of step they're picking.
            Image(systemName: "paperplane")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary)
        case .appleShortcut:
            Image(nsImage: AppleShortcutsService.appIcon)
                .resizable()
        case .inlineLLM:
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch item {
        case .caiAction(let name), .caiDestination(let name), .appleShortcut(let name):
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextPrimary)
        case .inlineLLM(let directive):
            Text(directive.isEmpty ? "LLM step" : "Use as LLM prompt")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextPrimary)
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.caiPrimary.opacity(0.15) }
        if isHovered { return Color.caiPrimary.opacity(0.08) }
        return Color.clear
    }
}
