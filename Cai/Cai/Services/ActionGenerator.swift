import Foundation

// MARK: - Action Generator

/// Generates context-aware actions based on content type and user preferences.
/// LLM actions are always shown regardless of server availability — errors are
/// handled at execution time.
///
/// Structure: Custom Action → type-specific actions → universal text actions.
/// Universal text actions appear for all types except JSON and bare URLs,
/// so misdetection never locks the user out of useful actions.
struct ActionGenerator {

    static func generateActions(
        for text: String,
        detection: ContentResult,
        settings: CaiSettings
    ) -> [ActionItem] {
        var items: [ActionItem] = []
        var shortcut = 1
        let hidden = settings.hiddenBuiltInActions

        // Pinned custom shortcuts come first, ahead of Ask AI and all built-ins.
        for sc in settings.shortcuts where sc.pinned {
            items.append(actionItem(from: sc, clipboardText: text, shortcut: shortcut))
            shortcut += 1
        }

        // Ask AI — first built-in, hideable.
        if !hidden.contains("custom_prompt") {
            items.append(ActionItem(
                id: "custom_prompt",
                title: "Ask AI",
                subtitle: text.isEmpty ? "Ask anything" : "Ask AI anything about this content",
                icon: "bolt.fill",
                shortcut: shortcut,
                type: .customPrompt
            ))
            shortcut += 1
        }

        // Empty clipboard — only Ask AI + destinations (user can also Cmd+N or Cmd+0)
        if detection.type == .empty {
            // Skip straight to destinations below
            let destinationStart = items.last?.shortcut ?? 0
            var destShortcut = destinationStart
            var seenDestIDs = Set<UUID>()
            for dest in settings.actionListDestinations {
                guard seenDestIDs.insert(dest.id).inserted else { continue }
                destShortcut += 1
                items.append(ActionItem(
                    id: "dest_\(dest.id.uuidString)",
                    title: dest.name,
                    subtitle: "Send to \(dest.name)",
                    icon: dest.icon,
                    shortcut: destShortcut,
                    type: .outputDestination(dest)
                ))
            }
            return items
        }

        // --- Type-specific actions ---

        var appendTextActions = true

        switch detection.type {

        // MARK: Cai Extension
        case .caiExtension:
            items.append(ActionItem(
                id: "install_extension",
                title: "Install Extension",
                subtitle: "Add this extension to Cai",
                icon: "puzzlepiece.extension",
                shortcut: shortcut,
                type: .installExtension
            ))
            return items  // No other actions for extension YAML

        // MARK: Word
        case .word:
            if !hidden.contains("define_word") {
                items.append(ActionItem(
                    id: "define_word",
                    title: "Define Word",
                    subtitle: "Look up definition",
                    icon: "character.book.closed",
                    shortcut: shortcut,
                    type: .llmAction(.define)
                ))
                shortcut += 1
            }

        // MARK: Short Text, Long Text
        case .shortText, .longText:
            break  // no type-specific actions, universal text actions cover it

        // MARK: Meeting
        case .meeting:
            let dateText = detection.entities.dateText ?? "event"
            items.append(ActionItem(
                id: "create_event",
                title: "Create Calendar Event",
                subtitle: dateText,
                icon: "calendar.badge.plus",
                shortcut: shortcut,
                type: .createCalendar(
                    title: "Meeting",
                    date: detection.entities.date ?? Date(),
                    location: detection.entities.location,
                    description: "\"\(text)\""
                )
            ))
            shortcut += 1

            if let location = detection.entities.location {
                items.append(ActionItem(
                    id: "open_maps",
                    title: "Open in Maps",
                    subtitle: location,
                    icon: "map",
                    shortcut: shortcut,
                    type: .openMaps(location)
                ))
                shortcut += 1
            }

        // MARK: Address
        case .address:
            let address = detection.entities.address ?? text
            items.append(ActionItem(
                id: "open_maps",
                title: "Open in Maps",
                subtitle: address,
                icon: "map",
                shortcut: shortcut,
                type: .openMaps(address)
            ))
            shortcut += 1

        // MARK: URL
        case .url:
            // Open in Browser first for bare URLs.
            // If there's substantial text beyond the URL, show it after text actions.
            let textBeyondURL: Int = {
                if let urlString = detection.entities.url {
                    return text.replacingOccurrences(of: urlString, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).count
                }
                return 0
            }()

            if textBeyondURL <= 30 {
                // Bare URL — just Open in Browser, no text actions
                if let urlString = detection.entities.url, let url = URL(string: urlString) {
                    items.append(ActionItem(
                        id: "open_url",
                        title: "Open in Browser",
                        subtitle: urlString,
                        icon: "safari",
                        shortcut: shortcut,
                        type: .openURL(url)
                    ))
                }
                appendTextActions = false
            }
            // URL+text: text actions will be appended below, then Open in Browser at the end

        // MARK: Image (OCR text)
        case .image:
            items.append(ActionItem(
                id: "extract_text",
                title: "Extracted Text",
                subtitle: "Review the text extracted from image",
                icon: "doc.text.viewfinder",
                shortcut: shortcut,
                type: .copyText
            ))
            shortcut += 1
            // appendTextActions stays true → Summarize, Explain, Reply, Proofread, Translate added below

        // MARK: JSON
        case .json:
            items.append(ActionItem(
                id: "pretty_print",
                title: "Pretty Print JSON",
                subtitle: "Format and copy to clipboard",
                icon: "curlybraces",
                shortcut: shortcut,
                type: .jsonPrettyPrint(text)
            ))
            appendTextActions = false

        case .empty:
            break  // handled by early return above
        }

        // --- Universal text actions ---
        // Shown for types where they make sense. Other actions are discoverable via search.
        // Reply/Fix Grammar: only for prose (shortText, longText, image)
        // Summarize: only for longer text (≥100 chars)
        // Explain/Translate: for all text types
        // Search: skip for long text

        let isProse = [.shortText, .longText, .image].contains(detection.type)
        let isLong = detection.type == .longText

        if appendTextActions {
            shortcut = (items.last?.shortcut ?? 0) + 1

            // Summarize — only for longer text (≥100 chars)
            if text.count >= 100 && !hidden.contains("summarize") {
                items.append(ActionItem(
                    id: "summarize",
                    title: "Summarize",
                    subtitle: "Create a concise summary",
                    icon: "text.redaction",
                    shortcut: shortcut,
                    type: .llmAction(.summarize)
                ))
                shortcut += 1
            }

            if !hidden.contains("explain") {
                items.append(ActionItem(
                    id: "explain",
                    title: "Explain",
                    subtitle: "Get an explanation",
                    icon: "lightbulb",
                    shortcut: shortcut,
                    type: .llmAction(.explain)
                ))
                shortcut += 1
            }

            // Reply / Proofread — only for prose content (not meetings, addresses, or single words)
            if isProse {
                if !hidden.contains("reply") {
                    items.append(ActionItem(
                        id: "reply",
                        title: "Reply",
                        subtitle: "Draft a reply",
                        icon: "arrowshape.turn.up.left",
                        shortcut: shortcut,
                        type: .llmAction(.reply)
                    ))
                    shortcut += 1
                }

                if !hidden.contains("proofread") {
                    items.append(ActionItem(
                        id: "proofread",
                        title: "Fix Grammar",
                        subtitle: "Fix grammar, spelling, and punctuation",
                        icon: "pencil.and.outline",
                        shortcut: shortcut,
                        type: .llmAction(.proofread)
                    ))
                    shortcut += 1
                }
            }

            if !hidden.contains("translate") {
                let lang = settings.translationLanguage
                items.append(ActionItem(
                    id: "translate",
                    title: "Translate to \(lang)",
                    subtitle: nil,
                    icon: "globe",
                    shortcut: shortcut,
                    type: .llmAction(.translate(lang))
                ))
                shortcut += 1
            }

            // Search — skip for long text (nobody searches a paragraph)
            if !isLong && !hidden.contains("search_web") {
                items.append(ActionItem(
                    id: "search_web",
                    title: "Search Web",
                    subtitle: nil,
                    icon: "magnifyingglass",
                    shortcut: shortcut,
                    type: .search(text)
                ))
                shortcut += 1
            }

            // URL+text: append Open in Browser after text actions
            if detection.type == .url,
               let urlString = detection.entities.url,
               let url = URL(string: urlString) {
                items.append(ActionItem(
                    id: "open_url",
                    title: "Open in Browser",
                    subtitle: urlString,
                    icon: "safari",
                    shortcut: shortcut,
                    type: .openURL(url)
                ))
                shortcut += 1
            }
        }

        // Append MCP-powered actions (e.g., "Create GitHub Issue", "Create Linear Issue")
        // One action per connected server with matching tools. Appears after built-in actions, before destinations.
        shortcut = items.last?.shortcut ?? 0
        for actionConfig in MCPActionConfigRegistry.shared.availableActions {
            shortcut += 1
            items.append(ActionItem(
                id: "mcp_\(actionConfig.id)",
                title: actionConfig.displayName,
                subtitle: nil,
                icon: actionConfig.icon,
                shortcut: shortcut,
                type: .mcpAction(configId: actionConfig.id)
            ))
        }

        // Append output destinations configured for action list display (direct routing)
        // Use a seen set to guard against duplicate destination IDs in persisted data.
        shortcut = items.last?.shortcut ?? 0
        var seenDestIDs = Set<UUID>()
        for dest in settings.actionListDestinations {
            guard seenDestIDs.insert(dest.id).inserted else { continue }
            shortcut += 1
            items.append(ActionItem(
                id: "dest_\(dest.id.uuidString)",
                title: dest.name,
                subtitle: "Send to \(dest.name)",
                icon: dest.icon,
                shortcut: shortcut,
                type: .outputDestination(dest)
            ))
        }

        return items
    }

    /// Generates ALL possible actions regardless of content type.
    /// Used for filter-to-reveal: default view shows type-specific actions,
    /// but typing to search reveals everything.
    static func generateAllActions(
        for text: String,
        detection: ContentResult,
        settings: CaiSettings
    ) -> [ActionItem] {
        // Start with the primary (type-filtered) actions
        let primary = generateActions(for: text, detection: detection, settings: settings)
        var seenIDs = Set(primary.map(\.id))
        var extras: [ActionItem] = []

        // Add universal text actions that may have been excluded (JSON, bare URL)
        let textActions = universalTextActions(for: text, settings: settings)
        for action in textActions where !seenIDs.contains(action.id) {
            seenIDs.insert(action.id)
            extras.append(action)
        }

        // Add type-specific actions from other types (only if entity-independent)
        if detection.type != .json {
            let jsonAction = ActionItem(
                id: "pretty_print",
                title: "Pretty Print JSON",
                subtitle: "Format and copy to clipboard",
                icon: "curlybraces",
                shortcut: 0,
                type: .jsonPrettyPrint(text)
            )
            if !seenIDs.contains(jsonAction.id) {
                seenIDs.insert(jsonAction.id)
                extras.append(jsonAction)
            }
        }

        // Define Word — surface in filter-to-reveal even when the user has hidden it
        // or when the content type isn't a single word.
        let defineAction = ActionItem(
            id: "define_word",
            title: "Define Word",
            subtitle: "Look up definition",
            icon: "character.book.closed",
            shortcut: 0,
            type: .llmAction(.define)
        )
        if !seenIDs.contains(defineAction.id) {
            seenIDs.insert(defineAction.id)
            extras.append(defineAction)
        }

        // Ask AI — surface in filter-to-reveal even when hidden from the default list.
        if !seenIDs.contains("custom_prompt") {
            seenIDs.insert("custom_prompt")
            extras.append(ActionItem(
                id: "custom_prompt",
                title: "Ask AI",
                subtitle: text.isEmpty ? "Ask anything" : "Ask AI anything about this content",
                icon: "bolt.fill",
                shortcut: 0,
                type: .customPrompt
            ))
        }

        // Open in Browser — if text contains a URL but wasn't detected as URL type
        if detection.type != .url, let urlString = extractFirstURL(from: text), let url = URL(string: urlString) {
            let browserAction = ActionItem(
                id: "open_url",
                title: "Open in Browser",
                subtitle: urlString,
                icon: "safari",
                shortcut: 0,
                type: .openURL(url)
            )
            if !seenIDs.contains(browserAction.id) {
                seenIDs.insert(browserAction.id)
                extras.append(browserAction)
            }
        }

        // Search Web — if not already included
        if !seenIDs.contains("search_web") && text.count <= 500 {
            extras.append(ActionItem(
                id: "search_web",
                title: "Search Web",
                subtitle: nil,
                icon: "magnifyingglass",
                shortcut: 0,
                type: .search(text)
            ))
        }

        // Extras have shortcut 0 (no number) — they only appear when filtering
        return primary + extras
    }

    // MARK: - Helpers

    /// Returns ALL universal text actions without content guards.
    /// Used by generateAllActions() for filter-to-reveal — the user explicitly searched,
    /// so we show everything and let them decide.
    private static func universalTextActions(
        for text: String,
        settings: CaiSettings
    ) -> [ActionItem] {
        var items: [ActionItem] = []

        items.append(ActionItem(
            id: "summarize",
            title: "Summarize",
            subtitle: "Create a concise summary",
            icon: "text.redaction",
            shortcut: 0,
            type: .llmAction(.summarize)
        ))

        items.append(ActionItem(
            id: "explain",
            title: "Explain",
            subtitle: "Get an explanation",
            icon: "lightbulb",
            shortcut: 0,
            type: .llmAction(.explain)
        ))

        items.append(ActionItem(
            id: "reply",
            title: "Reply",
            subtitle: "Draft a reply",
            icon: "arrowshape.turn.up.left",
            shortcut: 0,
            type: .llmAction(.reply)
        ))

        items.append(ActionItem(
            id: "proofread",
            title: "Fix Grammar",
            subtitle: "Fix grammar, spelling, and punctuation",
            icon: "pencil.and.outline",
            shortcut: 0,
            type: .llmAction(.proofread)
        ))

        let lang = settings.translationLanguage
        items.append(ActionItem(
            id: "translate",
            title: "Translate to \(lang)",
            subtitle: nil,
            icon: "globe",
            shortcut: 0,
            type: .llmAction(.translate(lang))
        ))

        return items
    }

    /// Extracts the first URL from text using NSDataDetector.
    private static func extractFirstURL(from text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        return match?.url?.absoluteString
    }

    /// Converts a `CaiShortcut` into an `ActionItem` for the action list.
    /// Shared by `generateActions` (pinned shortcuts) and `ActionListWindow.filteredActions`
    /// (filter-to-reveal) so the two paths stay in sync.
    static func actionItem(
        from sc: CaiShortcut,
        clipboardText: String,
        shortcut: Int
    ) -> ActionItem {
        let actionType: ActionType
        let subtitle: String
        switch sc.type {
        case .prompt:
            actionType = .llmAction(.custom(sc.value))
            subtitle = sc.value
        case .url:
            actionType = .shortcutURL(sc.value)
            let preview = String(clipboardText.prefix(20))
            let suffix = clipboardText.count > 20 ? "…" : ""
            subtitle = sc.value.replacingOccurrences(of: "%s", with: preview + suffix)
        case .shell:
            actionType = .shortcutShell(sc.value)
            subtitle = sc.value
        }

        return ActionItem(
            id: "shortcut_\(sc.id.uuidString)",
            title: sc.name,
            subtitle: subtitle,
            icon: sc.type.icon,
            shortcut: shortcut,
            type: actionType,
            autoReplaceSelection: sc.type == .prompt && sc.autoReplaceSelection
        )
    }
}
