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

        // Custom Action (⌘1) — always first, for ALL content types
        items.append(ActionItem(
            id: "custom_prompt",
            title: "Custom Action",
            subtitle: "Ask AI anything about this content",
            icon: "bolt.fill",
            shortcut: shortcut,
            type: .customPrompt
        ))
        shortcut += 1

        // --- Type-specific actions ---

        var appendTextActions = true

        switch detection.type {

        // MARK: Word
        case .word:
            items.append(ActionItem(
                id: "define_word",
                title: "Define Word",
                subtitle: "Look up definition",
                icon: "character.book.closed",
                shortcut: shortcut,
                type: .llmAction(.define)
            ))
            shortcut += 1

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
        }

        // --- Universal text actions ---
        // Appended for all types except JSON and bare URLs.
        // Some actions are skipped for specific types where they don't make sense.

        let isWord = detection.type == .word
        let isLong = detection.type == .longText

        if appendTextActions {
            shortcut = (items.last?.shortcut ?? 0) + 1

            // Summarize — only for longer text (≥100 chars)
            if text.count >= 100 {
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

            items.append(ActionItem(
                id: "explain",
                title: "Explain",
                subtitle: "Get an explanation",
                icon: "lightbulb",
                shortcut: shortcut,
                type: .llmAction(.explain)
            ))
            shortcut += 1

            // Reply / Proofread — skip for single words
            if !isWord {
                items.append(ActionItem(
                    id: "reply",
                    title: "Reply",
                    subtitle: "Draft a reply",
                    icon: "arrowshape.turn.up.left",
                    shortcut: shortcut,
                    type: .llmAction(.reply)
                ))
                shortcut += 1

                items.append(ActionItem(
                    id: "proofread",
                    title: "Proofread",
                    subtitle: "Fix grammar and spelling",
                    icon: "pencil.and.outline",
                    shortcut: shortcut,
                    type: .llmAction(.proofread)
                ))
                shortcut += 1
            }

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

            // Search — skip for long text (nobody searches a paragraph)
            if !isLong {
                items.append(ActionItem(
                    id: "search_web",
                    title: "Search Web",
                    subtitle: nil,
                    icon: "magnifyingglass",
                    shortcut: shortcut,
                    type: .search(text)
                ))
            }

            // URL+text: append Open in Browser after text actions
            if detection.type == .url,
               let urlString = detection.entities.url,
               let url = URL(string: urlString) {
                shortcut += 1
                items.append(ActionItem(
                    id: "open_url",
                    title: "Open in Browser",
                    subtitle: urlString,
                    icon: "safari",
                    shortcut: shortcut,
                    type: .openURL(url)
                ))
            }
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
}
