import CaiActionCore
import SwiftUI

/// Management screen for creating, editing, and deleting custom shortcuts.
/// Follows the same layout pattern as ClipboardHistoryView: header, scrollable
/// list, footer with keyboard hints.
struct ShortcutsManagementView: View {
    @ObservedObject var settings = CaiSettings.shared
    let onBack: () -> Void
    var onBrowseExtensions: (() -> Void)?
    /// When `false`, skip the screen header + footer. Used by
    /// `ActionsManagementView` which provides its own header (with the
    /// TabBar) and footer at the parent level.
    var showsChrome: Bool = true
    /// External trigger for "begin adding" — lets the tabbed parent's `+`
    /// button drive the same flow as this view's internal `addButton`.
    /// Bumping this UUID cancels any in-progress form and opens a fresh
    /// add form, no view remount required.
    var externalAddTrigger: UUID? = nil

    @State private var editingShortcutId: UUID?
    @State private var isAddingNew: Bool = false
    /// Tracks which row is hovered so the leading icon can morph into a pin
    /// affordance for unpinned shortcuts (mirrors `ClipboardHistoryView`).
    @State private var hoveredShortcutId: UUID?

    // Form fields
    @State private var formName: String = ""
    @State private var formType: CaiShortcut.ShortcutType = .prompt
    @State private var formValue: String = ""
    @State private var formAutoReplace: Bool = false
    @State private var formPinned: Bool = false
    @State private var formRunInBackground: Bool = false
    /// Chain steps to run after this action. Edited via the
    /// `ChainStepsTokenField` chip editor — supports Cai actions (named),
    /// inline LLM directives, and Apple Shortcuts. Lookup happens at chain
    /// time in `ChainExecutor`; for `.action` steps, shortcuts win on
    /// collision with destinations.
    @State private var formNext: [ChainStep] = []

    /// Names of Cai actions available for chain autocomplete: user shortcuts
    /// (excluding the one being edited — chaining to self is a cycle) plus
    /// chainable built-in actions (Summarize, Explain, Reply, Fix Grammar,
    /// Translate). Kept separate from destinations so the dropdown can
    /// section + icon them differently.
    private func availableActionNames(excluding excludeId: UUID?) -> [String] {
        let shortcutNames = settings.shortcuts
            .filter { $0.id != excludeId }
            .map(\.name)
        let builtInActionNames = BuiltInActionID.allCases
            .filter { $0.isChainable }
            .map(\.displayLabel)
        return shortcutNames + builtInActionNames
    }

    /// Names of all output destinations (built-in + custom) available for
    /// chain autocomplete. Resolver in `ChainExecutor` prefers user shortcuts
    /// on collision so users can override a built-in by naming a custom
    /// action the same. Computed on each render so settings changes
    /// propagate without refresh.
    private var availableDestinationNames: [String] {
        settings.outputDestinations.map(\.name)
    }
    /// Tracks whether the *previous* known formValue contained `|llm`. Used by
    /// the auto-enable heuristic for "Run in background" so we only fire on
    /// transitions, never on initial editor population (which would otherwise
    /// override a user's persisted opt-out for a `|llm` shortcut).
    /// Reset explicitly when the form is opened (Add or Edit) and on cancel.
    @State private var lastFormValueHadLLM: Bool = false

    /// Whether the "Then run" chip editor is expanded inline. Auto-set to
    /// `true` when entering edit mode on a shortcut with non-empty `next`,
    /// so users immediately see the chain. Stays collapsed for new actions
    /// and edits of un-chained actions until the user clicks the chip.
    @State private var thenRunExpanded: Bool = false

    /// Which field's `(?)` help popover is open (nil = none open).
    /// Used to show in-context explanations without permanent grey helper text.
    @State private var openHelpPopover: HelpField?

    enum HelpField: String, Identifiable {
        case value, thenRun
        var id: String { rawValue }
    }

    /// Display order for the Settings list and the action list: pinned first
    /// (in user-defined drag order), unpinned after (also in user order).
    /// `settings.shortcuts` is the canonical store; this is only a view.
    private var orderedShortcuts: [CaiShortcut] {
        settings.shortcuts.filter(\.pinned) + settings.shortcuts.filter { !$0.pinned }
    }

    /// Drag-to-reorder handler. Operates on `orderedShortcuts` indices, then
    /// re-sorts so the pinned-first invariant holds: a row dragged across the
    /// pinned/unpinned boundary snaps back to the boundary on drop.
    private func moveShortcut(from source: IndexSet, to destination: Int) {
        var working = orderedShortcuts
        working.move(fromOffsets: source, toOffset: destination)
        settings.shortcuts = working.filter(\.pinned) + working.filter { !$0.pinned }
    }

    /// Toggle pin from the leading icon button. Maintains the pinned-first
    /// invariant so the row visually moves to its new section on toggle.
    private func togglePin(_ shortcut: CaiShortcut) {
        guard let index = settings.shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            var copy = settings.shortcuts
            copy[index].pinned.toggle()
            settings.shortcuts = copy.filter(\.pinned) + copy.filter { !$0.pinned }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsChrome {
                screenHeader
                Divider().background(Color.caiDivider)
            }
            content
            if showsChrome {
                Spacer(minLength: 0)
                Divider().background(Color.caiDivider)
                footer
            }
        }
        // Wires the tabbed parent's `+` button: each time the parent
        // bumps `externalAddTrigger`, cancel any in-progress form and
        // open a fresh add form. The parent must NOT also wrap this view
        // in `.id(customAddRequest)` — `.id` remounts the view, the new
        // instance has no "previous" trigger value, and `.onChange` won't
        // fire. See `_docs/architecture/SWIFTUI_GOTCHAS.md`.
        .onChange(of: externalAddTrigger) { _, _ in
            cancelForm()
            beginAdding()
        }
    }

    /// Top-right `+` always visible, even when a form is open. Clicking
    /// while editing cancels the in-progress form (no discard prompt —
    /// same policy as the × in the editor) and opens a fresh add form.
    /// Public so the tabbed parent (`ActionsManagementView`) can render an
    /// equivalent button in its header without depending on `showsChrome`.
    var addButton: some View {
        Button(action: {
            cancelForm()
            beginAdding()
        }) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.caiPrimary)
        }
        .buttonStyle(.plain)
        .help("Add a new custom action")
    }

    private var screenHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiPrimary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Custom Actions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)

                Text(settings.shortcuts.isEmpty
                     ? "Type to filter actions when Cai is open"
                     : "\(settings.shortcuts.count) custom action\(settings.shortcuts.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
            }

            Spacer()

            addButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Footer with the Esc keyboard hint. Hidden when the view is embedded
    /// in a tabbed parent (parent owns its own footer).
    private var footer: some View {
        HStack(spacing: 12) {
            KeyboardHint(key: "Esc", label: "Back")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The list of shortcuts + inline edit/add form. Reusable inside both
    /// the standalone `ShortcutsManagementView` and the tabbed
    /// `ActionsManagementView`'s Custom tab.
    private var content: some View {
        // `List` (not `ScrollView { VStack }`) so `.onMove` can wire up
        // drag-to-reorder. `.listStyle(.plain)` + per-row clear background
        // strips List's default chrome so rows keep their card aesthetic.
        // ScrollViewReader lets us auto-scroll the editing/adding form into
        // view so the screen doesn't appear to "jump" when content below
        // the fold expands.
        ScrollViewReader { proxy in
        List {
            // Browse community extensions — at the top so discovery is
            // the first affordance the eye lands on, not a footer
            // afterthought. Hidden during edit/add to keep the form
            // surface uncluttered. Empty state has its own browse CTA.
            if onBrowseExtensions != nil && !settings.shortcuts.isEmpty && !isAddingNew && editingShortcutId == nil {
                Button(action: { onBrowseExtensions?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 10, weight: .medium))
                        Text("Browse Community Extensions")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.caiPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 0, trailing: 8))
            }

            if settings.shortcuts.isEmpty && !isAddingNew {
                emptyState
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } else {
                ForEach(orderedShortcuts) { shortcut in
                    Group {
                        if editingShortcutId == shortcut.id {
                            shortcutForm(isNew: false, shortcutId: shortcut.id)
                        } else {
                            shortcutRow(shortcut)
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
                .onMove(perform: moveShortcut)

                if isAddingNew {
                    shortcutForm(isNew: true, shortcutId: nil)
                        .id("addNewShortcut")  // ScrollViewReader anchor
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
            }

            // Add button (when not already adding)
            if !isAddingNew && editingShortcutId == nil {
                Button(action: { beginAdding() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                        Text("Add Action")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.caiPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.caiPrimary.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Auto-scroll the form into view when entering edit / add mode.
        //
        // Deferred to fire AFTER the form's open animation completes
        // (`beginAdding` / `beginEditing` use `withAnimation(0.2)` to expand
        // the row). One runloop tick (`DispatchQueue.main.async`) wasn't
        // enough — scrollTo resolved while the row was still mid-animation
        // and at a smaller intermediate size, so it under-scrolled and the
        // form ended up half off-screen. Waiting ~220 ms (animation 0.2 s
        // + a small buffer for layout settle) gets a stable final size.
        .onChange(of: editingShortcutId) { _, newId in
            guard let id = newId else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
        .onChange(of: isAddingNew) { _, isAdding in
            guard isAdding else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("addNewShortcut", anchor: .top)
                }
            }
        }
        }  // end ScrollViewReader
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.circle")
                .font(.system(size: 28))
                .foregroundColor(.caiTextSecondary.opacity(0.4))
            Text("No custom actions yet")
                .font(.system(size: 13))
                .foregroundColor(.caiTextSecondary)
            Text("Create custom actions for prompts you use often\nor URLs you search frequently")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary.opacity(0.6))
                .multilineTextAlignment(.center)

            if onBrowseExtensions != nil {
                Button(action: { onBrowseExtensions?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 10, weight: .medium))
                        Text("Browse Community Extensions")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.caiPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding()
    }

    // MARK: - Shortcut Row

    private func shortcutRow(_ shortcut: CaiShortcut) -> some View {
        let isHovered = hoveredShortcutId == shortcut.id
        // Show the pin glyph when pinned (always) or hovered (progressive disclosure
        // for unpinned rows — same pattern as `ClipboardHistoryView.historyRow`).
        let showPinIcon = shortcut.pinned || isHovered
        // Names the chain references that aren't installed locally — flagged
        // via a warning glyph so the user can fix the chain before running it.
        let unresolvedSteps = settings.unresolvedChainSteps(in: shortcut.next)

        return HStack(spacing: 12) {
            // Leading icon — doubles as pin toggle on hover.
            Button(action: { togglePin(shortcut) }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(shortcut.pinned
                              ? Color.caiPrimary.opacity(0.15)
                              : Color.caiSurface.opacity(0.6))
                        .frame(width: 28, height: 28)

                    if showPinIcon {
                        Image(systemName: shortcut.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(shortcut.pinned
                                             ? .caiPrimary
                                             : .caiTextSecondary.opacity(0.5))
                    } else {
                        Image(systemName: shortcut.type.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.caiTextSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(shortcut.pinned ? "Unpin" : "Pin to top")

            // Name + value preview
            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                Text(shortcut.value)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Chain dependency warning — shown when `next:` references local
            // actions/destinations the user doesn't have installed yet.
            if !unresolvedSteps.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.caiError)
                    .help("Chain needs: \(unresolvedSteps.joined(separator: ", "))")
            }

            Spacer()

            // Linear-style trailing `…` menu — consolidates Edit, Share,
            // Delete into one affordance. This pattern was chosen
            // specifically because plain `.onTapGesture` on a List row
            // breaks SwiftUI's drag-to-reorder gesture (mouse-down event
            // is claimed by the tap recognizer, never reaches the List's
            // drag responder). A `Menu` button is a self-contained click
            // target — it doesn't claim drag events on the row body, so
            // drag-to-reorder keeps working. Verified 2026-05-07.
            Menu {
                Button(action: { beginEditing(shortcut) }) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(action: { duplicateShortcut(shortcutId: shortcut.id) }) {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button(action: { shareShortcutAsExtension(shortcut) }) {
                    Label("Share as Extension", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive, action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        settings.shortcuts.removeAll { $0.id == shortcut.id }
                    }
                }) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.caiSurface.opacity(0.4) : Color.clear)
        )
        .contentShape(Rectangle())
        // **No `.onTapGesture` on the row.** A plain `.onTapGesture` on a
        // SwiftUI `List` row claims the mouse-down event and breaks the
        // drag-to-reorder gesture (verified 2026-05-07: `simultaneousGesture`,
        // `.onTapGesture(count: 2)`, and other variants all exhibit the
        // same conflict). Editing is exposed via the trailing `…` menu's
        // "Edit" item — `Menu` is a self-contained click target that
        // doesn't claim drag events on the row body.
        .onHover { hovering in
            hoveredShortcutId = hovering ? shortcut.id : nil
        }
    }

    /// Populates the editor form for an existing shortcut. Extracted so both
    /// the row click and any future invocations (keyboard shortcut, context
    /// menu) can call into the same logic. The state mutation is wrapped in
    /// `withAnimation` so the row→form expansion is smoothed; the
    /// ScrollViewReader's `onChange(of: editingShortcutId)` handler then
    /// scrolls the form into view alongside the animation.
    private func beginEditing(_ shortcut: CaiShortcut) {
        formName = shortcut.name
        formType = shortcut.type
        formValue = shortcut.value
        formAutoReplace = shortcut.autoReplaceSelection
        formPinned = shortcut.pinned
        formRunInBackground = shortcut.runInBackground
        formNext = shortcut.next
        // Auto-expand the chain editor if the shortcut already has steps —
        // user immediately sees what's chained. Empty chains stay collapsed.
        thenRunExpanded = !shortcut.next.isEmpty
        // Seed the tracker with the loaded value's |llm state so the *first*
        // onChange triggered by populating formValue doesn't mistakenly auto-
        // flip the toggle on (which would override the user's persisted
        // choice for `|llm`-foreground shortcuts).
        lastFormValueHadLLM = shortcut.value.contains("|llm")
        withAnimation(.easeInOut(duration: 0.2)) {
            editingShortcutId = shortcut.id
        }
        WindowController.passThrough = true
    }

    /// Begins authoring a brand-new shortcut. Resets the form state and opens
    /// the inline form. Used by both the top-right `+` button and the
    /// bottom-of-list "Add Action" button so they stay in sync.
    private func beginAdding() {
        formName = ""
        formType = .prompt
        formValue = ""
        formAutoReplace = false
        formPinned = false
        formRunInBackground = false
        formNext = []
        thenRunExpanded = false  // collapsed for new actions
        lastFormValueHadLLM = false  // empty value, no |llm
        withAnimation(.easeInOut(duration: 0.2)) {
            isAddingNew = true
        }
        WindowController.passThrough = true
    }

    // MARK: - Shortcut Form (Add / Edit)
    //
    // Linear/Apple-inspired layout:
    // - Title row: [📌 pin] [H1 title] [⋯ menu] [× cancel]
    // - Type picker (no label, picker IS the affordance)
    // - Unified input field with auto-grow + (?) inline help + inline shell warning
    // - Bottom chip row: collapsible "Then run" + Background + Auto-replace toggles
    // - Bottom-right: Cancel + Save (⌘⏎)
    //
    // Decisions live in DESIGN.md "Decisions Log" 2026-05-04 (v1.7 redesign).

    private func shortcutForm(isNew: Bool, shortcutId: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow(isNew: isNew, shortcutId: shortcutId)

            typePicker

            valueField

            Divider()
                .padding(.vertical, 2)

            chipRow(shortcutId: shortcutId)

            // Save / Cancel buttons. Save is the primary action; pinned
            // bottom-right per macOS HIG. ⌘⏎ saves; Esc cancels (also dismisses
            // via the × in the title row). No discard prompt — re-opening the
            // editor restores the saved state.
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancelForm() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextSecondary)

                Button(action: {
                    saveForm(isNew: isNew, shortcutId: shortcutId)
                }) {
                    Text(isNew ? "Add Action" : "Save")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(saveDisabled
                                      ? Color.caiPrimary.opacity(0.4)
                                      : Color.caiPrimary)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(saveDisabled)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.caiSurface.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.caiDivider.opacity(0.3), lineWidth: 0.5)
        )
        // ESC dismisses the form in-place (back to the shortcuts list, not
        // out of the whole window). `.keyboardShortcut(.cancelAction)` on the
        // Cancel button below is the idiomatic SwiftUI way, but in this app
        // the shortcuts window has higher-priority cancel handling that can
        // win the responder race; `.onExitCommand` on the form view itself
        // catches ESC reliably while focus is anywhere inside the form.
        .onExitCommand {
            cancelForm()
        }
        // Auto-enable "Run in background" on transition INTO `|llm`. Two trigger
        // points are required because the user can author in either order:
        //   (a) set type to .shell, then type/paste a `|llm` template
        //   (b) type/paste a `|llm` template (with type still .prompt, the
        //       default), then switch type to .shell
        //
        // We track the previous-known `|llm` state explicitly via
        // `lastFormValueHadLLM` rather than trusting `onChange`'s `oldValue` —
        // because `oldValue` is "" on the FIRST onChange after editor open
        // (when populating an existing shortcut), which would falsely look like
        // a transition and override the user's persisted choice.
        .onChange(of: formValue) { _, newValue in
            // Fires per keystroke. Early-return cheaply when there's no
            // |llm-state transition — most keystrokes don't cross the boundary.
            let hasLLM = newValue.contains("|llm")
            guard hasLLM != lastFormValueHadLLM else { return }
            lastFormValueHadLLM = hasLLM
            // Only auto-enable the toggle on a NO-LLM → HAS-LLM transition,
            // and only for shell-type shortcuts. Removing |llm doesn't auto-
            // disable the toggle (one-way heuristic).
            guard formType == .shell, hasLLM, !formRunInBackground else { return }
            formRunInBackground = true
        }
        .onChange(of: formType) { _, newType in
            // Switching type to .shell while the value already contains |llm:
            // honor the same auto-enable heuristic so order-of-authoring doesn't
            // matter. Skip if user already toggled it on.
            guard newType == .shell else { return }
            if lastFormValueHadLLM && !formRunInBackground {
                formRunInBackground = true
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Form sub-views

    /// Title row: pin (left) | H1 title (placeholder + click-to-edit) | ⋯ menu | × close.
    /// Pin lives on the LEFT to match the action-list row pattern (pin
    /// always leads the title — established in `ClipboardHistoryView` and
    /// `shortcutRow` above).
    @ViewBuilder
    private func titleRow(isNew: Bool, shortcutId: UUID?) -> some View {
        HStack(spacing: 8) {
            // Pin button (left). Reuses the same visual pattern as
            // `shortcutRow`: filled indigo when pinned, outlined grey when not.
            Button(action: { formPinned.toggle() }) {
                Image(systemName: formPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(formPinned ? .caiPrimary : .caiTextSecondary.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(formPinned ? Color.caiPrimary.opacity(0.12) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help(formPinned ? "Unpin from top" : "Pin to top of action list")

            // H1 title — placeholder if empty, click anywhere to edit.
            // No "Name" label; the placeholder + size signals what the field is.
            TextField("Untitled action", text: $formName)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            Spacer()

            // ⋯ menu — only when editing existing (Duplicate / Share / Delete
            // make no sense for an action that doesn't exist yet).
            if !isNew, let id = shortcutId {
                optionsMenu(shortcutId: id)
            }

            // × cancel — top-right, Apple HIG. Same as Cancel button (no
            // discard prompt — re-opening restores saved state).
            Button(action: { cancelForm() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close without saving")
        }
    }

    /// Type picker — segmented control without a label. The picker IS the
    /// type selector; the segments themselves communicate intent.
    private var typePicker: some View {
        Picker("", selection: $formType) {
            ForEach(CaiShortcut.ShortcutType.allCases, id: \.self) { type in
                Text(type.label).tag(type)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    /// The action's value field — Prompt / URL / Shell. Auto-grows via
    /// `TextField(axis: .vertical)`. Monospaced for URL + Shell.
    /// Inline label includes a `(?)` help button (popover with full
    /// explanation) and, for Shell, a short inline warning.
    @ViewBuilder
    private var valueField: some View {
        let label: String = {
            switch formType {
            case .prompt: return "Prompt"
            case .url: return "URL template"
            case .shell: return "Shell command"
            }
        }()
        let useMonospaced = formType == .url || formType == .shell

        VStack(alignment: .leading, spacing: 6) {
            // Label row: label + (?) help + inline warning (Shell only).
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)

                helpButton(field: .value, helpText: valueFieldHelpText)

                if formType == .shell {
                    Spacer().frame(width: 4)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.caiError)
                    Text("Only use commands you trust")
                        .font(.system(size: 10))
                        .foregroundColor(.caiError)
                }

                Spacer()
            }

            // Multi-line editor via `MultilineTextEditor` (NSTextView
            // wrapper). Plain Return inserts a newline; ⌘⏎ saves via
            // direct callback; Esc cancels via direct callback; Tab
            // moves to next field. 2 lines tall by default, scrolls
            // beyond 4 lines. The callback approach bypasses SwiftUI's
            // `keyboardShortcut` chain (which doesn't reliably route
            // through NSTextView's responder chain).
            // Derive isNew + shortcutId from existing @State so callers
            // don't need to thread them through this computed property.
            let id = editingShortcutId
            let isNew = isAddingNew
            let editor = MultilineTextEditor(
                text: $formValue,
                placeholder: formType.placeholder,
                monospaced: useMonospaced,
                onCommit: { saveForm(isNew: isNew, shortcutId: id) },
                onCancel: { cancelForm() }
            )
            editor
                .formFieldShell()
        }
    }

    /// Bottom chip row — collapsible "Then run" + Background + Auto-replace.
    /// Each chip flips visual state (outlined → indigo-filled) on activation.
    /// "Then run" expands inline to the chip editor when clicked or when the
    /// chain has any steps (auto-expand on edit).
    @ViewBuilder
    private func chipRow(shortcutId: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // Then run — neutral disclosure chip (NOT a toggle). Distinct
                // visual language from the on/off chips to its right —
                // `caiSurface` background like `DestinationChip` in the result
                // view. Chevron flips on expansion. Counter shows step count
                // when chain is non-empty.
                ChipButton(
                    label: thenRunLabel,
                    icon: thenRunExpanded || !formNext.isEmpty ? "chevron.down" : "chevron.right",
                    isActive: thenRunExpanded || !formNext.isEmpty,
                    tooltip: "Chain follow-up actions",
                    action: { thenRunExpanded.toggle() }
                )

                // Silent — boolean toggle. Skips the result view; the menu
                // bar pulses + a terminal toast surfaces on completion.
                if formType == .shell || formType == .prompt {
                    ChipToggle(
                        label: "Silent",
                        icon: "eye.slash",
                        isOn: formRunInBackground,
                        tooltip: "Skip the result view; toast only",
                        action: { formRunInBackground.toggle() }
                    )
                }

                // Auto-replace — boolean toggle (prompt only).
                if formType == .prompt {
                    ChipToggle(
                        label: "Auto-replace",
                        icon: "return",
                        isOn: formAutoReplace,
                        tooltip: "Paste response over selection, skip review",
                        action: { formAutoReplace.toggle() }
                    )
                }

                Spacer()
            }

            // Then-run chip editor — visible only when expanded or chain non-empty.
            if thenRunExpanded || !formNext.isEmpty {
                ChainStepsTokenField(
                    steps: $formNext,
                    availableActionNames: availableActionNames(excluding: shortcutId),
                    availableDestinationNames: availableDestinationNames,
                    placeholder: "Search actions to add..."
                )
            }
        }
    }

    /// Label for the "Then run" chip — shows step count when chain is non-empty.
    private var thenRunLabel: String {
        if formNext.isEmpty { return "Then run" }
        return "Then run · \(formNext.count)"
    }

    /// `(?)` help button — opens a small popover with the full explanation.
    /// Same pattern Apple uses in System Settings.
    @ViewBuilder
    private func helpButton(field: HelpField, helpText: String) -> some View {
        Button(action: {
            openHelpPopover = (openHelpPopover == field) ? nil : field
        }) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .popover(
            isPresented: Binding(
                get: { openHelpPopover == field },
                set: { if !$0 { openHelpPopover = nil } }
            ),
            arrowEdge: .top
        ) {
            Text(helpText)
                .font(.system(size: 11))
                .foregroundColor(.caiTextPrimary)
                .padding(10)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-type help text for the value field's `(?)` popover.
    private var valueFieldHelpText: String {
        switch formType {
        case .prompt:
            return "The instruction sent to the LLM with your clipboard text. Be specific about format and what to preserve."
        case .url:
            return "URL template — use %s where the clipboard text should be inserted (auto-encoded). Example: https://reddit.com/search?q=%s"
        case .shell:
            return "Shell command run via /bin/zsh -c. Use {{result}} where the clipboard text should be inserted (auto-quoted). Text is also passed via stdin."
        }
    }

    /// `⋯` overflow menu — Duplicate / Share / Delete. Only shown when
    /// editing an existing action (these operations don't apply to a new,
    /// unsaved action).
    @ViewBuilder
    private func optionsMenu(shortcutId: UUID) -> some View {
        Menu {
            Button(action: { duplicateShortcut(shortcutId: shortcutId) }) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if let shortcut = settings.shortcuts.first(where: { $0.id == shortcutId }) {
                Button(action: { shareShortcutAsExtension(shortcut) }) {
                    Label("Share as Extension", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive, action: { deleteShortcut(shortcutId: shortcutId) }) {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("More options")
    }

    /// True when Save should be disabled (missing required fields).
    private var saveDisabled: Bool {
        formName.trimmingCharacters(in: .whitespaces).isEmpty
            || formValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Duplicate the shortcut — copy all fields, append " (Copy)" to the
    /// name, insert into settings. Closes the editor; user can immediately
    /// open the duplicate to rename.
    private func duplicateShortcut(shortcutId: UUID) {
        guard let original = settings.shortcuts.first(where: { $0.id == shortcutId }) else { return }
        let copy = CaiShortcut(
            name: "\(original.name) (Copy)",
            type: original.type,
            value: original.value,
            autoReplaceSelection: original.autoReplaceSelection,
            pinned: false,  // duplicates start unpinned to avoid stomping the user's action list
            runInBackground: original.runInBackground,
            next: original.next
        )
        withAnimation(.easeInOut(duration: 0.15)) {
            var working = settings.shortcuts
            working.append(copy)
            settings.shortcuts = working.filter(\.pinned) + working.filter { !$0.pinned }
        }
        cancelForm()
    }

    /// Delete the shortcut. Closes the editor.
    private func deleteShortcut(shortcutId: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            settings.shortcuts.removeAll { $0.id == shortcutId }
        }
        cancelForm()
    }

    // MARK: - Form Helpers

    private func saveForm(isNew: Bool, shortcutId: UUID?) {
        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize smart/curly quotes to straight quotes — macOS's smart-quote
        // autocorrect silently replaces typed quotes in text fields, and zsh
        // (Shell type) + URL schemes only understand straight quotes.
        var trimmedValue = formValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizingSmartQuotes()
        // Auto-migrate the v1 wrapped pattern (`'{{result}}'` / `"{{result}}"`)
        // → v2 (`{{result|shell}}`). The launch-time migration in
        // CaiSettings.init() handles existing shortcuts, but new shortcuts
        // authored after the one-shot flag is set need this per-save fallback.
        // No-op on already-v2 templates.
        if formType == .shell {
            trimmedValue = TemplateEngine.migrateShellTemplate(trimmedValue)
        }
        guard !trimmedName.isEmpty, !trimmedValue.isEmpty else { return }

        // Only the prompt type supports auto-replace; other types silently drop it.
        let autoReplace = formType == .prompt && formAutoReplace
        // Shell + prompt support background execution; URL drops it.
        let runInBackground = (formType == .shell || formType == .prompt) && formRunInBackground
        // Editor strips empty inline-LLM chips on commit, but defensively
        // filter again in case a programmatic update slipped past it.
        let nextSteps = formNext.filter { !$0.isEmpty }

        if isNew {
            let shortcut = CaiShortcut(
                name: trimmedName,
                type: formType,
                value: trimmedValue,
                autoReplaceSelection: autoReplace,
                pinned: formPinned,
                runInBackground: runInBackground,
                next: nextSteps
            )
            withAnimation(.easeInOut(duration: 0.15)) {
                // Build the new ordered array in a local, then assign once so
                // `shortcuts.didSet` (and the `caiInvalidateActionCache` it posts)
                // fires a single time per save.
                var copy = settings.shortcuts
                copy.append(shortcut)
                settings.shortcuts = copy.filter(\.pinned) + copy.filter { !$0.pinned }
            }
        } else if let id = shortcutId,
                  let index = settings.shortcuts.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.15)) {
                // Mutate a working copy so the @Published didSet fires once,
                // not once per property assignment.
                var copy = settings.shortcuts
                copy[index].name = trimmedName
                copy[index].type = formType
                copy[index].value = trimmedValue
                copy[index].autoReplaceSelection = autoReplace
                copy[index].pinned = formPinned
                copy[index].runInBackground = runInBackground
                copy[index].next = nextSteps
                settings.shortcuts = copy.filter(\.pinned) + copy.filter { !$0.pinned }
            }
        }

        cancelForm()
    }

    private func cancelForm() {
        WindowController.passThrough = false
        withAnimation(.easeInOut(duration: 0.15)) {
            isAddingNew = false
            editingShortcutId = nil
        }
        formName = ""
        formType = .prompt
        formValue = ""
        formAutoReplace = false
        formPinned = false
        formRunInBackground = false
        formNext = []
        thenRunExpanded = false
        openHelpPopover = nil
        lastFormValueHadLLM = false
    }

    // MARK: - Share as Extension

    private func shareShortcutAsExtension(_ shortcut: CaiShortcut) {
        var yaml = """
            # cai-extension
            name: \(shortcut.name)
            description: \(shortcut.name)
            author: your-github-username
            version: "1.0"
            tags: []
            icon: \(shortcut.type.icon)
            type: \(shortcut.type.rawValue)\n
            """

        switch shortcut.type {
        case .prompt:
            let indented = shortcut.value.components(separatedBy: "\n")
                .map { "  \($0)" }.joined(separator: "\n")
            yaml += "prompt: |\n\(indented)\n"
        case .url:
            yaml += "url: \"\(shortcut.value)\"\n"
        case .shell:
            let indented = shortcut.value.components(separatedBy: "\n")
                .map { "  \($0)" }.joined(separator: "\n")
            yaml += "command: |\n\(indented)\n"
        }

        // Append `next:` block if the shortcut has a chain. Empty chain → no-op.
        yaml += ExtensionParser.emitChainYAML(
            shortcut.next,
            destinationNames: Set(settings.outputDestinations.map { $0.name })
        )

        SystemActions.copyToClipboard(yaml)

        if let url = URL(string: "https://github.com/cai-layer/cai-extensions") {
            NSWorkspace.shared.open(url)
        }

        NotificationCenter.default.post(
            name: .caiShowToast,
            object: nil,
            userInfo: ["message": "Extension YAML copied"]
        )
    }
}

