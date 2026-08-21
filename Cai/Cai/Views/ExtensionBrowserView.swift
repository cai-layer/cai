import CaiActionCore
import SwiftUI

// MARK: - Catalog Filter

/// Pure filtering + chip derivation for the extension catalog.
///
/// Lives outside the view (and `nonisolated`) so the browse logic is testable
/// without a window: search text + selected tag chips in, filtered entries out.
/// The view owns no filtering rules of its own.
///
/// Tags are normalised because the catalog is remote data authored by hand:
/// untrimmed, mixed-case tags would render the same chip twice.
enum ExtensionCatalogFilter {

    /// Chips shown above the list. Six of the catalog's current tags plus the
    /// Clear control fit one row at the window's fixed width; a horizontally
    /// scrolling overflow would just be a hidden feature.
    static let chipLimit = 6

    /// Tags shown on a row before collapsing into a `+n` counter.
    static let rowTagLimit = 3

    /// Normalised, de-duplicated tags for one entry, in the author's order.
    nonisolated static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in raw {
            let normalized = normalize(tag)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

    /// The chip set, derived from the tags actually present in the catalog.
    ///
    /// Ordered by how many extensions carry the tag (descending), alphabetical
    /// on ties. No curated taxonomy and no content-type priority list: the
    /// catalog carries no content-type tags, and an ordering rule for data that
    /// does not exist would silently reshuffle the row the day it lands. That
    /// call belongs with the tagging pass in `cai-extensions`.
    nonisolated static func chipTags(for entries: [ExtensionService.ExtensionEntry]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in entries {
            for tag in normalizedTags(entry.tags) {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(chipLimit)
            .map(\.key)
    }

    /// Search text AND selected chips.
    ///
    /// Chips OR against each other: entries carry ~2 tags apiece, so ANDing two
    /// chips returns nothing almost every time, which reads as a broken filter.
    /// OR-within-one-facet is also what every faceted browser does.
    /// Chip matching is exact on normalised tags; search stays substring.
    nonisolated static func filter(
        _ entries: [ExtensionService.ExtensionEntry],
        searchText: String,
        selectedTags: Set<String>
    ) -> [ExtensionService.ExtensionEntry] {
        let query = normalize(searchText)
        guard !query.isEmpty || !selectedTags.isEmpty else { return entries }

        return entries.filter { entry in
            let tags = normalizedTags(entry.tags)

            if !selectedTags.isEmpty, selectedTags.isDisjoint(with: tags) { return false }
            guard !query.isEmpty else { return true }

            return entry.name.lowercased().contains(query)
                || entry.description.lowercased().contains(query)
                || tags.contains { $0.contains(query) }
        }
    }

    /// Trim, strip control and bidi characters, lowercase.
    ///
    /// The bidi strip matters because these strings are rendered: a tag
    /// carrying U+202E reorders the text around it, so a chip can read as
    /// something other than the tag it filters by. `.whitespacesAndNewlines`
    /// does not catch those, they are category Cf.
    private nonisolated static func normalize(_ value: String) -> String {
        value
            .strippingControlCharacters(keepingNewlines: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// Browse and install community extensions from the curated repo.
/// Follows the same layout pattern as ShortcutsManagementView.
struct ExtensionBrowserView: View {
    @ObservedObject var settings = CaiSettings.shared
    let onBack: () -> Void

    @State private var entries: [ExtensionService.ExtensionEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedTags: Set<String> = []
    @State private var installingSlug: String?
    @State private var loadTask: Task<Void, Never>?

    // Shell confirmation
    @State private var shellConfirmSlug: String?
    @State private var shellConfirmCommand: String = ""
    @State private var shellConfirmName: String = ""

    @FocusState private var isSearchFocused: Bool

    private var displayedEntries: [ExtensionService.ExtensionEntry] {
        ExtensionCatalogFilter.filter(entries, searchText: searchText, selectedTags: selectedTags)
    }

    private var chipTags: [String] {
        ExtensionCatalogFilter.chipTags(for: entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.caiPrimary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Extensions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.caiTextPrimary)

                    Text("Browse community extensions")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.caiDivider)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary.opacity(0.5))
                TextField("Search extensions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.caiSurface.opacity(0.4))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFocused = true
                }
            }

            // Filter chips. Hidden while loading / erroring so the vertical
            // budget goes to content, and hidden when the catalog carries no
            // tags at all.
            if !isLoading, errorMessage == nil, !chipTags.isEmpty {
                filterChipRow
            }

            // Content
            ScrollView {
                VStack(spacing: 4) {
                    if isLoading {
                        loadingState
                    } else if let error = errorMessage {
                        errorState(error)
                    } else if entries.isEmpty {
                        catalogEmptyState
                    } else if displayedEntries.isEmpty {
                        emptyState
                    } else {
                        ForEach(displayedEntries) { entry in
                            extensionRow(entry)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack(spacing: 12) {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .task { await loadExtensions() }
        .alert("Install Shell Command", isPresented: Binding(
            get: { shellConfirmSlug != nil },
            set: { if !$0 { shellConfirmSlug = nil } }
        )) {
            Button("Cancel", role: .cancel) { shellConfirmSlug = nil }
            Button("Install") {
                if let slug = shellConfirmSlug {
                    confirmShellInstall(slug: slug, name: shellConfirmName, command: shellConfirmCommand)
                }
            }
        } message: {
            Text("This extension will run the following command on your clipboard text:\n\n\(shellConfirmCommand)")
        }
    }

    // MARK: - Filter Chips

    private var filterChipRow: some View {
        HStack(spacing: 6) {
            // Tags render lowercase, exactly as authored, on both surfaces.
            // `.capitalized` would turn the catalog's acronym tags into "Css"
            // and "Ai", and lowercase suits the passive register of a tag.
            ForEach(chipTags, id: \.self) { tag in
                TagFilterChip(
                    label: tag,
                    isOn: selectedTags.contains(tag),
                    tooltip: selectedTags.contains(tag)
                        ? "Stop filtering by \(tag)"
                        : "Show only \(tag) extensions"
                ) {
                    toggleTag(tag)
                }
            }

            // Clear is an action, not a toggle, so it does not wear a chip:
            // Chip.swift keeps those vocabularies apart, and a chip labelled
            // "Clear" would collide with a catalog tag of the same name.
            if !selectedTags.isEmpty {
                Button("Clear") { selectedTags.removeAll() }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiPrimary)
                    .help("Clear tag filters")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading extensions...")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding()
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 28))
                .foregroundColor(.caiTextSecondary.opacity(0.4))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await loadExtensions() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.caiPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding()
    }

    /// The catalog itself came back empty. Distinct from `emptyState`, which
    /// blames a filter: with nothing typed and nothing selected, "no match"
    /// would be a lie about the user's input.
    private var catalogEmptyState: some View {
        VStack(spacing: 8) {
            Text("No extensions available")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
            Button("Retry") { Task { await loadExtensions() } }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.caiPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(selectedTags.isEmpty
                 ? "No extensions match your search"
                 : "No extensions match your filters")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)

            // A dead end needs a way out that is right here, not a Clear
            // control the user has to go find in the row above. Scoped to the
            // chips: a no-hit search query is its own undo in the focused
            // field, and wiping what someone just typed is not a favour.
            if !selectedTags.isEmpty {
                Button("Clear filters") {
                    selectedTags.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.caiPrimary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding()
    }

    // MARK: - Extension Row

    private func extensionRow(_ entry: ExtensionService.ExtensionEntry) -> some View {
        let isInstalled = settings.installedExtensions.contains(entry.slug)
        let isInstalling = installingSlug == entry.slug

        return HStack(spacing: 10) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.caiSurface.opacity(0.6))
                    .frame(width: 28, height: 28)

                Image(systemName: entry.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
            }

            // Name + description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                        .lineLimit(1)

                    tagPill(entry.type.capitalized)
                }

                Text(entry.description)
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary)
                    .lineLimit(1)

                metadataLine(entry)
            }

            Spacer()

            // Install button. NB: we use the `Button { action } label: { … }`
            // form rather than the `Button(_ title: String, action:)` short
            // form because modifiers like `.padding` and `.background` applied
            // *outside* the Button only affect layout, not the hit area —
            // clicks landing on the padded margin would miss the button. The
            // explicit label + `.contentShape(Rectangle())` makes the entire
            // styled rectangle a click target.
            if isInstalling {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 60)
            } else {
                Button {
                    if isInstalled {
                        uninstallExtension(entry)
                    } else {
                        Task { await installExtension(entry) }
                    }
                } label: {
                    Text(isInstalled ? "Installed" : "Install")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isInstalled ? .caiTextSecondary : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isInstalled ? Color.caiSurface.opacity(0.6) : Color.caiPrimary)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.caiSurface.opacity(0.3))
        .cornerRadius(8)
    }

    // MARK: - Load

    /// Serialised deliberately: `.task` starts one load and every Retry click
    /// starts another, each with a 15s timeout. Two in flight and the slower
    /// one wins the last write, which paints "Could not load extensions" over
    /// a catalog that arrived fine (or restores stale rows over fresh ones).
    private func loadExtensions() async {
        loadTask?.cancel()
        let task = Task { await fetchCatalog() }
        loadTask = task
        await task.value
    }

    private func fetchCatalog() async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await ExtensionService.fetchIndex()
            guard !Task.isCancelled else { return }
            entries = fetched
            // Drop selections the refreshed catalog no longer offers a chip
            // for, otherwise the list stays filtered by something invisible.
            selectedTags.formIntersection(ExtensionCatalogFilter.chipTags(for: entries))
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            #if DEBUG
            print("[ExtensionBrowser] Load failed: \(error)")
            #endif
            errorMessage = "Could not load extensions"
            isLoading = false
        }
    }

    // MARK: - Install

    private func installExtension(_ entry: ExtensionService.ExtensionEntry) async {
        // One install at a time. Two concurrent installs share a single
        // `installingSlug` spinner and a single shell-confirmation slot, so the
        // slower fetch would overwrite the command text under an alert the user
        // is already reading, and their "Install" would approve a command they
        // were never shown.
        guard installingSlug == nil, shellConfirmSlug == nil else { return }

        installingSlug = entry.slug
        defer { installingSlug = nil }

        do {
            let yaml = try await ExtensionService.fetchYAML(slug: entry.slug)

            // Shell: show confirmation alert before installing
            if entry.type == "shell" {
                let parsed = try ExtensionParser.parse(yaml, allowShell: true)
                if case .shortcut(let sc, _, _) = parsed {
                    await MainActor.run {
                        guard shellConfirmSlug == nil else { return }
                        shellConfirmName = sc.name
                        shellConfirmCommand = sc.value
                        shellConfirmSlug = entry.slug
                    }
                }
                return
            }

            let parsed = try ExtensionParser.parse(yaml, allowShell: false)
            await MainActor.run {
                saveParsedExtension(parsed, slug: entry.slug)
            }
        } catch {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .caiShowToast, object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }
    }

    private func confirmShellInstall(slug: String, name: String, command: String) {
        let shortcut = CaiShortcut(name: name, type: .shell, value: command)
        settings.shortcuts.append(shortcut)
        settings.installedExtensions.insert(slug)
        shellConfirmSlug = nil
        // Shell extensions don't carry chains today (the parser doesn't read
        // `next:` for the un-confirmed shell path because the user hasn't
        // approved the command yet), so no chain-deps check needed here.
    }

    private func saveParsedExtension(_ parsed: ExtensionParser.ParsedExtension, slug: String) {
        let name: String
        let importedChain: [ChainStep]
        switch parsed {
        case .shortcut(let shortcut, _, _):
            name = shortcut.name
            importedChain = shortcut.next
            // Avoid duplicates by name
            if !settings.shortcuts.contains(where: { $0.name == shortcut.name }) {
                settings.shortcuts.append(shortcut)
            }
        case .destination(let destination, _, _):
            name = destination.name
            importedChain = destination.next
            if !settings.outputDestinations.contains(where: { $0.name == destination.name }) {
                settings.outputDestinations.append(destination)
            }
        }
        settings.installedExtensions.insert(slug)

        // Standard install toast — augmented with a chain-deps suffix when
        // the imported chain references items not installed locally. The
        // persistent badge on the row is the durable indicator; this toast
        // is a one-shot heads-up at install time. Same toast format as the
        // clipboard install path in `ActionListWindow.confirmInstallExtension`.
        NotificationCenter.default.post(
            name: .caiShowToast, object: nil,
            userInfo: ["message": ExtensionParser.installToastMessage(
                name: name, chain: importedChain, settings: settings)]
        )
    }

    // MARK: - Uninstall

    private func uninstallExtension(_ entry: ExtensionService.ExtensionEntry) {
        // Remove shortcut or destination by matching name
        settings.shortcuts.removeAll { $0.name == entry.name }
        settings.outputDestinations.removeAll { $0.name == entry.name }
        settings.installedExtensions.remove(entry.slug)
    }

    /// The author of the first-party catalog. Their name on 53 of 60 rows is
    /// texture with no information, so it is suppressed and "by <author>" is
    /// left to mean what it should on an install surface: this one came from
    /// someone else. Every row carries its author in the tooltip regardless.
    private static let firstPartyAuthor = "cai-layer"

    /// Tags + author, the row's third line.
    ///
    /// Tags are passive labels, not controls: same treatment as the type badge,
    /// no indigo (Indigo discipline: they describe, they do not act), and a 9pt
    /// pill could not carry the 44pt hit target a control owes. Filtering by
    /// tag is the chip row's job.
    ///
    /// Capped at `rowTagLimit` with a `+n` counter so a long tag list cannot
    /// stretch the row; the full list is in the tooltip.
    private func metadataLine(_ entry: ExtensionService.ExtensionEntry) -> some View {
        let tags = ExtensionCatalogFilter.normalizedTags(entry.tags)
        let shown = Array(tags.prefix(ExtensionCatalogFilter.rowTagLimit))
        let overflow = tags.count - shown.count
        let author = entry.author
            .strippingControlCharacters(keepingNewlines: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(shown, id: \.self) { tag in
                    tagPill(tag)
                }

                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.caiTextSecondary.opacity(0.7))
                }
            }
            if !author.isEmpty, author != Self.firstPartyAuthor {
                Text("by \(author)")
                    .font(.system(size: 9))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // One tooltip for the whole line, carrying the author even on the rows
        // whose byline is suppressed: hiding a repeated name is a density
        // choice, and provenance must not be the thing it costs.
        .help(metadataTooltip(tags: tags, author: author))
    }

    private func metadataTooltip(tags: [String], author: String) -> String {
        let parts = [tags.joined(separator: ", "), author.isEmpty ? "" : "by \(author)"]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The row's small-label treatment, shared by the type badge and the tags
    /// so the two cannot drift apart.
    ///
    /// Clamped: every string here (`tags`, `type`) comes from remote catalog
    /// JSON, so one over-long value would otherwise wrap and stretch the row.
    private func tagPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.caiTextSecondary.opacity(0.7))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 90, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.caiSurface.opacity(0.8))
            .cornerRadius(4)
    }
}

// MARK: - Tag Filter Chip

/// Selectable tag chip for the browse row.
///
/// Visually identical to `ChipToggle` (Chip.swift) on purpose: same radius,
/// fill, border and indigo on-state, so the app keeps one chip vocabulary. It
/// is a local copy only because `ChipToggle` requires an icon and tags have
/// none; folding the two together is a follow-up.
///
/// Deviation on record: 24pt tall, under the 44pt minimum in DESIGN.md. It
/// matches the existing chips rather than introducing a second chip size on
/// one surface, and the whole 24pt rectangle is the hit area.
private struct TagFilterChip: View {
    let label: String
    let isOn: Bool
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? .caiPrimary : .caiTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // The label is a catalog tag, i.e. remote data: one absurd tag
                // must not push the rest of the row off the window. 110pt
                // clears the longest real tag ("productivity", 81pt) with room
                // to spare, so only hostile lengths ever truncate.
                .frame(maxWidth: 110)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(backgroundFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .help(tooltip)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        // The chip row unmounts on reload and on error, and SwiftUI does not
        // reliably deliver `onHover(false)` to a view that is going away, so a
        // pushed cursor would outlive the chip.
        .onDisappear {
            if isHovered {
                NSCursor.pop()
                isHovered = false
            }
        }
    }

    private var backgroundFill: Color {
        if isOn { return Color.caiPrimary.opacity(0.12) }
        if isHovered { return Color.caiSurface.opacity(0.8) }
        return Color.caiSurface.opacity(0.5)
    }

    private var borderColor: Color {
        // Keyboard focus borrows the indigo focus-ring rule from form fields:
        // a tabbed-to chip has to be visible before the mouse matters.
        if isOn || isFocused { return Color.caiPrimary.opacity(0.4) }
        return Color(nsColor: .separatorColor).opacity(0.5)
    }

    private var borderWidth: CGFloat {
        isFocused ? 1 : 0.5
    }
}
