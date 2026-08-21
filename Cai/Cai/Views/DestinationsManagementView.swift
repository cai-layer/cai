import CaiActionCore
import SwiftUI

/// CRUD view for managing output destinations.
/// Built-in destinations (Replace Selection, Email, Notes, Reminders) have
/// enable/disable toggles. Custom destinations support full create/edit/
/// delete with type-specific config.
///
/// **Tabbed layout (2026-05-05):** mirrors `ActionsManagementView` — top
/// segmented bar splits Built-in (toggle-only rows) from Custom (full CRUD
/// + inline edit form). The form (when editing/adding) only renders inside
/// the Custom tab.
struct DestinationsManagementView: View {
    @ObservedObject var settings = CaiSettings.shared
    let onBack: () -> Void
    var onBrowseExtensions: (() -> Void)?

    enum Tab: Hashable { case builtIn, custom }
    @State private var selectedTab: Tab = .custom

    @State private var editingDestinationId: UUID?
    @State private var isAddingNew: Bool = false
    @State private var hoveredDestinationId: UUID?

    // Form fields
    @State private var formName: String = ""
    @State private var formTypeTag: String = "webhook"
    @State private var formShowInActionList: Bool = false
    /// Chain steps to run after this destination's side-effect. Edited via
    /// the `ChainStepsTokenField` chip editor — supports Cai actions (named),
    /// inline LLM directives, and Apple Shortcuts.
    @State private var formNext: [ChainStep] = []

    /// Names of Cai actions available for chain autocomplete: all user
    /// shortcuts + chainable built-in actions (Summarize, Explain, Reply,
    /// Fix Grammar, Translate). Kept separate from destinations so the
    /// dropdown can section + icon them differently.
    private var availableActionNames: [String] {
        let shortcutNames = settings.shortcuts.map(\.name)
        let builtInActionNames = BuiltInActionID.allCases
            .filter { $0.isChainable }
            .map(\.displayLabel)
        return shortcutNames + builtInActionNames
    }

    /// Names of all output destinations (built-in + custom) available for
    /// chain autocomplete, excluding the one being edited (chaining to self
    /// is a cycle the executor would catch, but suggesting it is misleading).
    /// Resolver in `ChainExecutor` prefers user shortcuts on collision so
    /// users can override a built-in by naming a custom action the same.
    private func availableDestinationNames(excluding excludeId: UUID?) -> [String] {
        settings.outputDestinations
            .filter { $0.id != excludeId }
            .map(\.name)
            // Synthetic, never persisted — see BuiltInDestinations.showInCai.
            + [BuiltInDestinations.showInCai.name]
    }

    // AppleScript
    @State private var formAppleScript: String = ""

    // Webhook
    @State private var formWebhookURL: String = ""
    @State private var formWebhookMethod: String = "POST"
    @State private var formWebhookHeaders: String = "{\"Content-Type\": \"application/json\"}"
    @State private var formWebhookBody: String = ""

    // Deeplink
    @State private var formDeeplink: String = ""

    // Shell
    @State private var formShellCommand: String = ""

    // Setup fields
    @State private var formSetupFields: [SetupField] = []

    /// Whether the "Then run" chip editor is expanded inline. Auto-set to
    /// `true` when entering edit mode on a destination with non-empty
    /// `next`. Mirrors `ShortcutsManagementView.thenRunExpanded`.
    @State private var thenRunExpandedDest: Bool = false

    /// Which form field's `(?)` help popover is open (nil = none).
    @State private var openHelpPopoverDest: HelpFieldDest?

    enum HelpFieldDest: String, Identifiable {
        case webhook, applescript, deeplink, shell, setupFields
        var id: String { rawValue }
    }

    var body: some View {
        ManagementScreen(
            icon: "paperplane.circle.fill",
            title: "Destinations",
            subtitle: headerSubtitle,
            tabs: [
                .init(id: .custom, label: "Custom", count: customCount),
                .init(id: .builtIn, label: "Built-in", count: enabledBuiltInCount)
            ],
            selection: $selectedTab,
            customTabId: .custom,
            onAdd: beginAddingDestination
        ) {
            // Each tab gets its own root container so the Custom tab's
            // `List + .onMove` doesn't sit inside a `switch`-produced
            // `_ConditionalContent` (SwiftUI's drag-to-reorder gesture is
            // flaky when wrapped in conditional content — the
            // `.onMove` fails to register a drop indicator).
            //
            // - Built-in tab: simple `ScrollView { VStack }` — no List
            //   needed, no drag.
            // - Custom tab: chrome-stripped `List` with the ForEach.onMove
            //   pattern, exactly mirroring `ShortcutsManagementView.content`
            //   (which is known-working at the same structural level).
            switch selectedTab {
            case .builtIn:
                ScrollView {
                    VStack(spacing: 4) {
                        builtInTabContent
                    }
                    .padding(.vertical, 8)
                }
            case .custom:
                ScrollViewReader { proxy in
                    List {
                        customTabContent
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // Deferred ~220 ms to fire AFTER the form's open animation
                    // completes (`beginAddingDestination` uses `withAnimation(0.15)`).
                    // See the same comment in `ShortcutsManagementView` — single
                    // `DispatchQueue.main.async` wasn't enough because scrollTo
                    // resolved against the form's intermediate animated size.
                    .onChange(of: isAddingNew) { _, isAdding in
                        guard isAdding else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo("addNewDestination", anchor: .top)
                            }
                        }
                    }
                    .onChange(of: editingDestinationId) { _, newId in
                        guard let id = newId else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            WindowController.acceptsFilterInput = false
        }
    }

    /// Fired when the user taps the header's `+` button on the Custom tab.
    /// Cancels any in-progress form (no discard prompt — same policy as
    /// the editor's `×`) and opens a fresh add form.
    private func beginAddingDestination() {
        cancelForm()
        resetForm()
        WindowController.passThrough = true
        withAnimation(.easeInOut(duration: 0.15)) {
            isAddingNew = true
        }
    }

    private var customCount: Int {
        settings.outputDestinations.filter { !$0.isBuiltIn }.count
    }

    private var enabledBuiltInCount: Int {
        settings.outputDestinations.filter { $0.isBuiltIn && $0.isEnabled }.count
    }

    private var headerSubtitle: String {
        switch selectedTab {
        case .custom:
            return customCount == 0
                ? "Webhooks, AppleScript, deeplinks, shell"
                : "\(customCount) custom destination\(customCount == 1 ? "" : "s")"
        case .builtIn:
            let total = settings.outputDestinations.filter { $0.isBuiltIn }.count
            return "\(enabledBuiltInCount) of \(total) enabled"
        }
    }

    // MARK: - Tab Content

    /// Built-in destinations — toggle-only rows (Replace Selection, Email,
    /// Notes, Reminders). Rendered inside a plain `ScrollView { VStack }`
    /// (no List, no drag-to-reorder needed for the Built-in tab).
    @ViewBuilder
    private var builtInTabContent: some View {
        // `chainOnly` built-ins (e.g. Copy to Clipboard) are hidden from this
        // toggle list — their toggle would be decorative since they don't
        // appear in the result view either, and the entry would just clutter
        // the list. They're still selectable in the chain editor autocomplete.
        ForEach(settings.outputDestinations.filter { $0.isBuiltIn && !$0.chainOnly }) { dest in
            builtInRow(dest)
                .padding(.horizontal, 12)
        }

        // "Show in Cai" is synthetic (never persisted — see
        // BuiltInDestinations.showInCai), so it has no row above and no toggle
        // to own. It still needs one readable home: without it, both its
        // existence and its precedence rule live only in a code comment and a
        // 10pt autocomplete hint, and a user who puts it in a background action
        // watches nothing happen with no way to find out why.
        //
        // The Automation-permission footnote that used to sit here is gone on
        // purpose (master): System Access now covers it.
        showInCaiReferenceRow
            .padding(.horizontal, 12)
    }

    /// Custom destinations — pinned-first ordering, click-anywhere row,
    /// full CRUD with hover-revealed share + delete trailing buttons,
    /// inline edit form, drag-to-reorder via `.onMove`. Emits List rows
    /// directly. Mirrors `ShortcutsManagementView.content`'s structure so
    /// both Custom tabs feel identical.
    @ViewBuilder
    private var customTabContent: some View {
        // Browse extensions at the top (matches Custom Actions tab).
        if onBrowseExtensions != nil && !customDestinations.isEmpty && !isAddingNew && editingDestinationId == nil {
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

        if customDestinations.isEmpty && !isAddingNew {
            ManagementEmptyState(
                icon: "paperplane.circle",
                title: "No custom destinations yet",
                description: "Send results to webhooks, AppleScript, deeplinks, or shell commands.",
                ctaLabel: onBrowseExtensions != nil ? "Browse Community Extensions" : nil,
                ctaIcon: onBrowseExtensions != nil ? "square.grid.2x2" : nil,
                ctaAction: onBrowseExtensions
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } else {
            ForEach(customDestinations) { dest in
                Group {
                    if editingDestinationId == dest.id {
                        destinationForm(isNew: false, destinationId: dest.id)
                    } else {
                        customRow(dest)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
            .onMove(perform: moveCustomDestination)

            if isAddingNew {
                destinationForm(isNew: true, destinationId: nil)
                    .id("addNewDestination")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
        }

        // Bottom "Add Destination" button — mirrors the "Add Action" button
        // at the bottom of the Custom Actions tab. Hidden while a form is
        // open so the user has one obvious surface to interact with.
        if !isAddingNew && editingDestinationId == nil {
            Button(action: { beginAddingDestination() }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text("Add Destination")
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

    /// Drag-to-reorder handler for the Custom tab. No pinned-first
    /// invariant (destinations don't have pinning anymore — see
    /// `customRow`'s comment). User's drag order is the canonical order.
    private func moveCustomDestination(from source: IndexSet, to destination: Int) {
        var working = customDestinations
        working.move(fromOffsets: source, toOffset: destination)
        let builtIns = settings.outputDestinations.filter(\.isBuiltIn)
        settings.outputDestinations = builtIns + working
    }

    /// Custom destinations in user's drag order. No pin-based reordering
    /// (destinations don't have pinning).
    private var customDestinations: [OutputDestination] {
        settings.outputDestinations.filter { !$0.isBuiltIn }
    }

    // MARK: - Built-in Row

    /// Built-in destination row — matches `BuiltInActionsContent.actionRow`
    /// and `ConnectorsSettingsView` so all "list of toggleable items"
    /// surfaces in Settings share one visual vocabulary. Anatomy: 20pt-frame
    /// leading icon (14pt medium, `caiPrimary` when on) + label + subtitle
    /// + indigo switch on the right, wrapped in a `caiSurface.opacity(0.3)`
    /// rounded card.
    private func builtInRow(_ dest: OutputDestination) -> some View {
        let isEnabled = dest.isEnabled

        return HStack(spacing: 10) {
            Image(systemName: dest.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isEnabled ? .caiPrimary : .caiTextSecondary.opacity(0.5))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(dest.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                Text(builtInDestinationSubtitle(for: dest))
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { dest.isEnabled },
                set: { newValue in
                    if let index = settings.outputDestinations.firstIndex(where: { $0.id == dest.id }) {
                        settings.outputDestinations[index].isEnabled = newValue
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.caiPrimary)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.caiSurface.opacity(0.3))
        )
    }

    /// Reference row for the synthetic "Show in Cai" destination. Same shell as
    /// `builtInRow` minus the toggle — it is always available and has nothing to
    /// configure, so a switch would be a lie. The icon stays `caiPrimary`
    /// (always on) and the subtitle carries the background-precedence rule,
    /// which is the part that would otherwise surprise someone.
    @ViewBuilder
    private var showInCaiReferenceRow: some View {
        HStack(spacing: 10) {
            Image(systemName: BuiltInDestinations.showInCai.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiPrimary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(BuiltInDestinations.showInCai.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                Text("Ends a chain by showing its result in Cai. Background actions record it on the header pill instead.")
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Where the toggle would sit — states "always on" without pretending
            // to be interactive.
            Text("Always on")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.caiSurface.opacity(0.3))
        )
        .accessibilityElement(children: .combine)
    }

    /// Short, action-verb subtitle for a built-in destination — fills the
    /// "scope/status hint" slot under the row's primary label. Falls back
    /// to the type label for any future built-in not listed here.
    private func builtInDestinationSubtitle(for dest: OutputDestination) -> String {
        switch dest.name {
        case "Replace Selection":
            return "Paste over your selection in the source app"
        case "Email":
            return "Open a new draft in Mail"
        case "Save to Notes":
            return "Create a new note"
        case "Create Reminder":
            return "Add to your default list"
        default:
            return dest.type.label
        }
    }

    // MARK: - Custom Row

    /// Custom destination row — mirrors `shortcutRow` design language.
    /// Editing happens via the trailing `…` menu (no row-level click-to-
    /// edit, since `.onTapGesture` would break List's drag-to-reorder).
    /// **No pin button (2026-05-07):** destinations don't need pinning —
    /// they're passive sinks, not commands competing for action-list
    /// position. `showInActionList` controls visibility; drag-to-reorder
    /// controls order within this management list.
    private func customRow(_ dest: OutputDestination) -> some View {
        let isHovered = hoveredDestinationId == dest.id
        // Names the chain references that aren't installed locally — flagged
        // via a warning glyph so the user can fix the chain before running it.
        // Mirrors the same pattern in `ShortcutsManagementView.shortcutRow`.
        let unresolvedSteps = settings.unresolvedChainSteps(in: dest.next)

        return HStack(spacing: 12) {
            // Leading icon — purely decorative now (no pin toggle).
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.caiSurface.opacity(0.6))
                    .frame(width: 28, height: 28)

                Image(systemName: dest.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiPrimary)
            }

            // Name + type
            VStack(alignment: .leading, spacing: 1) {
                Text(dest.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                Text(dest.type.label)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
            }

            // Chain dependency warning (icon-only — leaves the existing
            // "Setup needed" pill below as the field-config indicator;
            // these signal different problems and shouldn't merge).
            if !unresolvedSteps.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.caiError)
                    .help("Chain needs: \(unresolvedSteps.joined(separator: ", "))")
            }

            Spacer()

            if !dest.isConfigured {
                Text("Setup needed")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.caiError)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.caiError.opacity(0.1))
                    .cornerRadius(4)
            }

            // Linear-style trailing `…` menu — Edit / Duplicate / Share /
            // Delete in one affordance. Mirrors `shortcutRow` for visual
            // consistency. Crucially: a `Menu` button is a self-contained
            // click target, so it doesn't claim mouse-down on the row body
            // — `List`'s drag-to-reorder gesture continues to work. A plain
            // `.onTapGesture` here would break drag (verified 2026-05-07).
            Menu {
                Button(action: {
                    loadFormFromDestination(dest)
                    WindowController.passThrough = true
                    editingDestinationId = dest.id
                }) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(action: { duplicateDestination(destinationId: dest.id) }) {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button(action: { shareDestinationAsExtension(dest) }) {
                    Label("Share as Extension", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive, action: {
                    deleteDestination(destinationId: dest.id)
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
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.caiSurface.opacity(0.4) : Color.clear)
        )
        .contentShape(Rectangle())
        // No `.onTapGesture` on the row — would break List's drag-to-reorder
        // (any tap-gesture variant claims mouse-down and the drag never
        // initiates). Editing is exposed via the `…` menu's "Edit" item.
        .onHover { hovering in
            hoveredDestinationId = hovering ? dest.id : nil
        }
    }

    // MARK: - Form

    /// Destination edit/create form — Linear/Apple-inspired layout, mirrors
    /// the Custom Actions form: H1 click-to-edit title, leading pin, ⋯ menu
    /// + × close top-right, type picker (no label), per-type fields with
    /// (?) inline help popovers, inline shell/AppleScript warnings,
    /// setup-fields list (kept — they're config data, not chrome), bottom
    /// chip row (Show in action list / Then run), Save/Cancel bottom-right.
    /// Decisions live in DESIGN.md "Decisions Log" 2026-05-05.
    private func destinationForm(isNew: Bool, destinationId: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            destTitleRow(isNew: isNew, destinationId: destinationId)

            destTypePicker

            destValueFields

            setupFieldsSection

            Divider().padding(.vertical, 2)

            destChipRow(destinationId: destinationId)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancelForm() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextSecondary)

                Button(action: {
                    saveForm(isNew: isNew, destinationId: destinationId)
                }) {
                    Text(isNew ? "Add Destination" : "Save")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(destSaveDisabled
                                      ? Color.caiPrimary.opacity(0.4)
                                      : Color.caiPrimary)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(destSaveDisabled)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Form sub-views

    /// Shared multi-line input for all type-specific code/template fields.
    /// Auto-grows from 2 lines (default) up to 4 lines, then scrolls.
    /// Wraps `MultilineTextEditor` with the standard form-field shell.
    /// All template editors (Headers JSON, Body, AppleScript, Deeplink,
    /// Shell command) use this — single source of truth for height behavior
    /// + visual treatment.
    @ViewBuilder
    private func multilineField(text: Binding<String>, placeholder: String) -> some View {
        // Derive isNew + destinationId from existing form state so
        // callers don't need to thread them. ⌘⏎ saves the form even when
        // focus is in this field; Esc cancels. Bypasses SwiftUI's
        // `keyboardShortcut` chain (which doesn't reliably route through
        // NSTextView's responder chain).
        let id = editingDestinationId
        let isNew = isAddingNew
        let editor = MultilineTextEditor(
            text: text,
            placeholder: placeholder,
            monospaced: true,
            onCommit: { saveForm(isNew: isNew, destinationId: id) },
            onCancel: { cancelForm() }
        )
        editor
            .formFieldShell()
    }

    /// Title row: H1 placeholder + ⋯ menu + × cancel. (No pin button —
    /// destinations don't have pinning. See `customRow` for rationale.)
    @ViewBuilder
    private func destTitleRow(isNew: Bool, destinationId: UUID?) -> some View {
        HStack(spacing: 8) {
            TextField("Untitled destination", text: $formName)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            Spacer()

            if !isNew, let id = destinationId {
                destOptionsMenu(destinationId: id)
            }

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

    /// Type picker — no label. Picker IS the type selector.
    private var destTypePicker: some View {
        Picker("", selection: $formTypeTag) {
            Text("Webhook").tag("webhook")
            Text("AppleScript").tag("applescript")
            Text("Deeplink").tag("deeplink")
            Text("Shell").tag("shell")
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    /// Type-specific fields wrapper. Each type renders its own field group
    /// with inline label + (?) help + (where applicable) inline warning.
    @ViewBuilder
    private var destValueFields: some View {
        switch formTypeTag {
        case "webhook":
            destWebhookFields
        case "applescript":
            destAppleScriptFields
        case "deeplink":
            destDeeplinkFields
        case "shell":
            destShellFields
        default:
            EmptyView()
        }
    }

    /// Webhook fields — URL/method on one row, Headers + Body below.
    @ViewBuilder
    private var destWebhookFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            // URL + method on one row
            HStack(spacing: 6) {
                Text("Endpoint")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                helpButton(field: .webhook, helpText: webhookHelpText)
                Spacer()
            }
            HStack(spacing: 8) {
                Picker("", selection: $formWebhookMethod) {
                    Text("POST").tag("POST")
                    Text("PUT").tag("PUT")
                    Text("PATCH").tag("PATCH")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)

                TextField("https://… or {{slack_webhook_url}}", text: $formWebhookURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .formFieldShell()
            }

            // Headers JSON
            HStack(spacing: 6) {
                Text("Headers")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                if !isWebhookHeadersValid {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.caiError)
                    Text("Invalid JSON")
                        .font(.system(size: 10))
                        .foregroundColor(.caiError)
                }
                Spacer()
            }
            multilineField(
                text: $formWebhookHeaders,
                placeholder: "{ \"Content-Type\": \"application/json\" }"
            )

            // Body template
            HStack(spacing: 6) {
                Text("Body template")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                Spacer()
            }
            multilineField(
                text: $formWebhookBody,
                placeholder: "{ \"text\": \"{{result}}\" }"
            )
        }
    }

    @ViewBuilder
    private var destAppleScriptFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("AppleScript")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                helpButton(field: .applescript, helpText: appleScriptHelpText)
                Spacer().frame(width: 4)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.caiError)
                Text("Only use scripts you trust")
                    .font(.system(size: 10))
                    .foregroundColor(.caiError)
                Spacer()
            }
            multilineField(
                text: $formAppleScript,
                placeholder: "tell application \"Notes\" to make new note with properties {body: \"{{result}}\"}"
            )
        }
    }

    @ViewBuilder
    private var destDeeplinkFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Deeplink")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                helpButton(field: .deeplink, helpText: deeplinkHelpText)
                Spacer()
            }
            multilineField(
                text: $formDeeplink,
                placeholder: "bear://x-callback-url/create?text={{result}}"
            )
        }
    }

    @ViewBuilder
    private var destShellFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Shell command")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                helpButton(field: .shell, helpText: shellHelpText)
                Spacer().frame(width: 4)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.caiError)
                Text("Only use commands you trust")
                    .font(.system(size: 10))
                    .foregroundColor(.caiError)
                Spacer()
            }
            multilineField(
                text: $formShellCommand,
                placeholder: "echo {{result}} | pbcopy"
            )
        }
    }

    /// Setup fields list — kept structurally (they're config data per
    /// destination, not form chrome). Visual treatment slightly tightened
    /// to match the new design language: smaller key prefix, plain inputs
    /// on `caiSurface`, eye toggle for secrets, minus to remove.
    @ViewBuilder
    private var setupFieldsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Setup fields")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                helpButton(field: .setupFields, helpText: setupFieldsHelpText)
                Spacer()
            }

            ForEach($formSetupFields) { $field in
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Text("{{")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                        TextField("key", text: $field.key)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 80)
                        Text("}}")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )

                    Group {
                        if field.isSecret {
                            SecureField("Value", text: $field.value)
                        } else {
                            TextField("Value", text: $field.value)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )

                    Button(action: { field.isSecret.toggle() }) {
                        Image(systemName: field.isSecret ? "eye.slash.fill" : "eye")
                            .font(.system(size: 10))
                            .foregroundColor(field.isSecret ? .orange : .caiTextSecondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(field.isSecret ? "Secret field (hidden)" : "Visible field")

                    Button(action: {
                        formSetupFields.removeAll { $0.id == field.id }
                    }) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Remove setup field")
                }
            }

            Button(action: {
                // Default to hidden — setup fields typically hold webhook
                // URLs, API tokens, or other secrets. Safer for screen-share
                // / pair-programming. Users can click the eye to reveal.
                formSetupFields.append(SetupField(key: "", isSecret: true))
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10))
                    Text("Add setup field")
                        .font(.system(size: 10))
                }
                .foregroundColor(.caiPrimary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Bottom chip row — Then run + Show in action list. Same chip
    /// vocabulary as Custom Actions: neutral disclosure chip for "Then
    /// run", indigo toggle chip for "Show in action list".
    @ViewBuilder
    private func destChipRow(destinationId: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ChipButton(
                    label: destThenRunLabel,
                    icon: thenRunExpandedDest || !formNext.isEmpty ? "chevron.down" : "chevron.right",
                    isActive: thenRunExpandedDest || !formNext.isEmpty,
                    tooltip: "Chain follow-up actions",
                    action: { thenRunExpandedDest.toggle() }
                )

                ChipToggle(
                    label: "Show in action list",
                    icon: "eye",
                    isOn: formShowInActionList,
                    tooltip: "Show as a direct-route chip in the result view",
                    action: { formShowInActionList.toggle() }
                )

                Spacer()
            }

            if thenRunExpandedDest || !formNext.isEmpty {
                ChainStepsTokenField(
                    steps: $formNext,
                    availableActionNames: availableActionNames,
                    availableDestinationNames: availableDestinationNames(excluding: destinationId),
                    placeholder: "Search actions to add..."
                )
            }
        }
    }

    private var destThenRunLabel: String {
        if formNext.isEmpty { return "Then run" }
        return "Then run · \(formNext.count)"
    }

    /// `(?)` help button — same pattern as Custom Actions.
    @ViewBuilder
    private func helpButton(field: HelpFieldDest, helpText: String) -> some View {
        Button(action: {
            openHelpPopoverDest = (openHelpPopoverDest == field) ? nil : field
        }) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .popover(
            isPresented: Binding(
                get: { openHelpPopoverDest == field },
                set: { if !$0 { openHelpPopoverDest = nil } }
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

    private var webhookHelpText: String {
        "POST/PUT/PATCH to a URL. Use {{result}} for the LLM result, {{key}} for setup-field values. The body template is sent verbatim — make sure the JSON is valid."
    }

    private var appleScriptHelpText: String {
        "Runs via osascript. Use {{result}} for the LLM result — strings are auto-escaped for AppleScript. {{key}} resolves setup fields."
    }

    private var deeplinkHelpText: String {
        "Opens a URL scheme like bear://, things://, or omnifocus://. Use {{result}} for the LLM result (auto-encoded). {{key}} resolves setup fields."
    }

    private var shellHelpText: String {
        "Runs via /bin/zsh -c. Use {{result}} for the LLM result (auto-quoted). The result is also passed via stdin."
    }

    private var setupFieldsHelpText: String {
        "Configurable values referenced by {{key}} in your URL/template/body. Webhook URLs, API tokens, channel names — anything you'd otherwise hardcode. Mark as secret to hide the value in the editor."
    }

    /// `⋯` overflow menu — Duplicate / Share as Extension / Delete.
    @ViewBuilder
    private func destOptionsMenu(destinationId: UUID) -> some View {
        Menu {
            Button(action: { duplicateDestination(destinationId: destinationId) }) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if let dest = settings.outputDestinations.first(where: { $0.id == destinationId }) {
                Button(action: { shareDestinationAsExtension(dest) }) {
                    Label("Share as Extension", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive, action: { deleteDestination(destinationId: destinationId) }) {
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

    private var destSaveDisabled: Bool {
        formName.trimmingCharacters(in: .whitespaces).isEmpty
            || (formTypeTag == "webhook" && !isWebhookHeadersValid)
    }

    /// Duplicate the destination — copy all fields, append " (Copy)" to
    /// name, append at the end of the custom destinations list.
    private func duplicateDestination(destinationId: UUID) {
        guard let original = settings.outputDestinations.first(where: { $0.id == destinationId }) else { return }
        let copy = OutputDestination(
            name: "\(original.name) (Copy)",
            icon: original.icon,
            type: original.type,
            isEnabled: true,
            isBuiltIn: false,
            showInActionList: original.showInActionList,
            setupFields: original.setupFields,
            next: original.next
        )
        withAnimation(.easeInOut(duration: 0.15)) {
            settings.outputDestinations.append(copy)
        }
        cancelForm()
    }

    /// Delete the destination. Closes the editor.
    private func deleteDestination(destinationId: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            settings.outputDestinations.removeAll { $0.id == destinationId }
        }
        cancelForm()
    }

    // (Per-type field helpers — destAppleScriptFields, destWebhookFields,
    // destDeeplinkFields, destShellFields — live above with the redesigned
    // form, replacing the older `appleScriptFields` / `webhookFields` /
    // `deeplinkFields` / `shellFields` helpers that used TextEditor +
    // labeled hints. The new versions use TextField(axis: .vertical) for
    // multi-line auto-grow and `(?)` popovers for help.)

    // MARK: - Form Helpers

    private func buildDestinationType() -> DestinationType {
        // Normalize smart/curly quotes in template fields — macOS's smart-quote
        // autocorrect silently replaces typed quotes, and zsh, URL schemes,
        // AppleScript, and JSON webhook bodies only understand straight quotes.
        switch formTypeTag {
        case "applescript":
            return .applescript(template: formAppleScript.normalizingSmartQuotes())
        case "webhook":
            let headers = parseHeaders(formWebhookHeaders.normalizingSmartQuotes())
            return .webhook(WebhookConfig(
                url: formWebhookURL.normalizingSmartQuotes(),
                method: formWebhookMethod,
                headers: headers,
                bodyTemplate: formWebhookBody.normalizingSmartQuotes()
            ))
        case "deeplink":
            return .deeplink(template: formDeeplink.normalizingSmartQuotes())
        case "shell":
            return .shell(command: formShellCommand.normalizingSmartQuotes())
        default:
            return .webhook(WebhookConfig(url: "", bodyTemplate: ""))
        }
    }

    private func parseHeaders(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return ["Content-Type": "application/json"]
        }
        return dict
    }

    /// Whether the webhook headers field currently contains a valid `[String: String]`
    /// JSON object (or is empty — empty falls back to the default Content-Type).
    /// Used to gate the Save button and show an inline warning. Without this gate
    /// the form would silently fall back to defaults on parse failure, which looked
    /// like a save bug from the user's perspective.
    private var isWebhookHeadersValid: Bool {
        let trimmed = formWebhookHeaders.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let normalized = formWebhookHeaders.normalizingSmartQuotes()
        guard let data = normalized.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data) as? [String: String]) != nil else {
            return false
        }
        return true
    }

    private func loadFormFromDestination(_ dest: OutputDestination) {
        formName = dest.name
        formShowInActionList = dest.showInActionList
        formSetupFields = dest.setupFields
        formNext = dest.next
        // Auto-expand the chain editor if there are steps already.
        thenRunExpandedDest = !dest.next.isEmpty

        switch dest.type {
        case .applescript(let template):
            formTypeTag = "applescript"
            formAppleScript = template
        case .webhook(let config):
            formTypeTag = "webhook"
            formWebhookURL = config.url
            formWebhookMethod = config.method
            if let data = try? JSONSerialization.data(withJSONObject: config.headers, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                formWebhookHeaders = str
            }
            formWebhookBody = config.bodyTemplate
        case .deeplink(let template):
            formTypeTag = "deeplink"
            formDeeplink = template
        case .shell(let command):
            formTypeTag = "shell"
            formShellCommand = command
        case .pasteBack:
            // pasteBack is a built-in destination and has no editable fields.
            // Built-in rows don't render an Edit button, so this case should be
            // unreachable — assert in debug, no-op in release rather than silently
            // coercing to a webhook form.
            assertionFailure("pasteBack is a built-in destination and cannot be edited")
            return
        case .clipboardCopy:
            // clipboardCopy is a built-in chain-only destination — same
            // contract as pasteBack: no editable fields, no Edit button
            // rendered. Reaching here is a code-path bug.
            assertionFailure("clipboardCopy is a built-in destination and cannot be edited")
            return
        case .showInCai:
            // Same contract as clipboardCopy: built-in, chain-only, no fields.
            assertionFailure("showInCai is a built-in destination and cannot be edited")
            return
        }
    }

    private func saveForm(isNew: Bool, destinationId: UUID?) {
        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let destType = buildDestinationType()
        // Token field already trims and drops empties — defensive re-filter
        // Editor strips empty inline-LLM chips on commit, but defensively
        // filter again in case a programmatic update slipped past it.
        let nextSteps = formNext.filter { !$0.isEmpty }

        if isNew {
            let dest = OutputDestination(
                name: trimmedName,
                icon: iconForTypeTag(formTypeTag),
                type: destType,
                isEnabled: true,
                isBuiltIn: false,
                showInActionList: formShowInActionList,
                setupFields: formSetupFields,
                next: nextSteps
            )
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.outputDestinations.append(dest)
            }
        } else if let id = destinationId,
                  let index = settings.outputDestinations.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.outputDestinations[index].name = trimmedName
                settings.outputDestinations[index].icon = iconForTypeTag(formTypeTag)
                settings.outputDestinations[index].type = destType
                settings.outputDestinations[index].showInActionList = formShowInActionList
                settings.outputDestinations[index].setupFields = formSetupFields
                settings.outputDestinations[index].next = nextSteps
            }
        }

        cancelForm()
    }

    private func iconForTypeTag(_ tag: String) -> String {
        switch tag {
        case "webhook": return "arrow.up.right.square"
        case "applescript": return "applescript"
        case "deeplink": return "link"
        case "shell": return "terminal"
        default: return "arrow.up.right.square"
        }
    }

    private func resetForm() {
        formName = ""
        formTypeTag = "webhook"
        formShowInActionList = false
        formAppleScript = ""
        formWebhookURL = ""
        formWebhookMethod = "POST"
        formWebhookHeaders = "{\"Content-Type\": \"application/json\"}"
        formWebhookBody = ""
        formDeeplink = ""
        formShellCommand = ""
        formSetupFields = []
        formNext = []
        thenRunExpandedDest = false
        openHelpPopoverDest = nil
    }

    private func cancelForm() {
        WindowController.passThrough = false
        withAnimation(.easeInOut(duration: 0.15)) {
            isAddingNew = false
            editingDestinationId = nil
        }
        // Defer the form @State reset by one runloop tick. The form contains
        // `ForEach($formSetupFields)` whose row TextFields commit on blur via
        // index-based bindings (`$formSetupFields[N].value`). If we clear
        // `formSetupFields` synchronously here, an in-flight commit triggered
        // by the teardown layout pass will index into an empty array and trap
        // (`Swift/ContiguousArrayBuffer.swift:691: Fatal error: Index out of range`).
        // Deferring lets SwiftUI detach the TextFields first; by next tick the
        // bindings are gone and clearing the array is safe.
        // Repro: open a webhook destination, type into a setup field's value,
        // click Save while focus is still in the field — pre-fix this crashes.
        DispatchQueue.main.async {
            self.resetForm()
        }
    }

    // MARK: - Share as Extension

    private func shareDestinationAsExtension(_ dest: OutputDestination) {
        var yaml = """
            # cai-extension
            name: \(dest.name)
            description: \(dest.name)
            author: your-github-username
            version: "1.0"
            tags: []
            icon: \(dest.icon)
            """

        switch dest.type {
        case .webhook(let config):
            yaml += "\ntype: webhook"
            yaml += "\nshow_in_action_list: \(dest.showInActionList)"
            yaml += "\nwebhook:"
            yaml += "\n  url: \"\(config.url)\""
            yaml += "\n  method: \(config.method)"
            if !config.headers.isEmpty {
                yaml += "\n  headers:"
                for (key, value) in config.headers {
                    yaml += "\n    \(key): \(value)"
                }
            }
            yaml += "\n  body: '\(config.bodyTemplate)'"

        case .deeplink(let template):
            yaml += "\ntype: deeplink"
            yaml += "\nshow_in_action_list: \(dest.showInActionList)"
            yaml += "\ndeeplink: \"\(template)\""

        case .shell(let command):
            let indented = command.components(separatedBy: "\n")
                .map { "  \($0)" }.joined(separator: "\n")
            yaml += "\ntype: shell"
            yaml += "\ncommand: |\n\(indented)"

        case .applescript(let template):
            let indented = template.components(separatedBy: "\n")
                .map { "  \($0)" }.joined(separator: "\n")
            yaml += "\ntype: applescript"
            yaml += "\napplescript: |\n\(indented)"

        case .pasteBack:
            // pasteBack is built-in only; not shareable as an extension.
            return
        case .clipboardCopy:
            // clipboardCopy is built-in only and chain-scoped; not
            // shareable as an extension.
            return
        case .showInCai:
            // showInCai is built-in only and has no config to share.
            return
        }

        // Setup fields
        if !dest.setupFields.isEmpty {
            yaml += "\nsetup:"
            for field in dest.setupFields {
                yaml += "\n  - key: \(field.key)"
                yaml += "\n    label: \(field.key)"
                yaml += "\n    secret: \(field.isSecret)"
            }
        }

        // Append `next:` block if the destination has a chain. Empty chain → no-op.
        yaml += ExtensionParser.emitChainYAML(
            dest.next,
            destinationNames: Set(settings.outputDestinations.map { $0.name })
        )

        yaml += "\n"

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
