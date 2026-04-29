import Foundation

// MARK: - Custom Shortcut Model

/// A user-defined shortcut that appears when typing to filter the action list.
/// Two types: prompt (sends clipboard text + saved prompt to LLM) and url
/// (opens a URL template with clipboard text substituted for %s).
struct CaiShortcut: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var type: ShortcutType
    var value: String  // prompt text or URL template with %s
    /// When true (prompt-type only), the LLM response is pasted straight over
    /// the user's current selection in the source app, skipping the result
    /// review UI. Defaults to false.
    var autoReplaceSelection: Bool

    enum ShortcutType: String, Codable, CaseIterable {
        case prompt
        case url
        case shell

        var icon: String {
            switch self {
            case .prompt: return "bolt.circle.fill"
            case .url: return "safari.fill"
            case .shell: return "terminal.fill"
            }
        }

        var label: String {
            switch self {
            case .prompt: return "Prompt"
            case .url: return "URL"
            case .shell: return "Shell"
            }
        }

        var placeholder: String {
            switch self {
            case .prompt: return "e.g. Rewrite as a professional email reply"
            case .url: return "e.g. https://www.reddit.com/search/?q=%s"
            case .shell: return "e.g. echo '{{result}}' | base64 -D"
            }
        }
    }

    init(id: UUID = UUID(), name: String, type: ShortcutType, value: String, autoReplaceSelection: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.value = value
        self.autoReplaceSelection = autoReplaceSelection
    }

    // Custom decoder so previously-persisted shortcuts (without the flag) still
    // decode, defaulting to false.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(ShortcutType.self, forKey: .type)
        self.value = try c.decode(String.self, forKey: .value)
        self.autoReplaceSelection = try c.decodeIfPresent(Bool.self, forKey: .autoReplaceSelection) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, value, autoReplaceSelection
    }
}

// MARK: - Smart-quote normalization

extension String {
    /// Replaces macOS "smart quotes" (curly typographic quotes inserted
    /// automatically by NSTextView / SwiftUI TextField when Substitutions →
    /// Smart Quotes is on) with straight ASCII quotes. Shell (zsh), URL
    /// schemes, JSON, and AppleScript all reject curly quotes — a user
    /// pasting or typing `'{{result}}'` into a Shortcut or Destination
    /// template gets `'{{result}}'`, which fails at runtime with an
    /// unhelpful "command not found" or parse error.
    ///
    /// Applied at save-time in ShortcutsManagementView and
    /// DestinationsManagementView. Not applied to user clipboard text —
    /// only to template definitions where curly quotes have no valid use.
    func normalizingSmartQuotes() -> String {
        self
            .replacingOccurrences(of: "\u{2018}", with: "'")   // ' left single
            .replacingOccurrences(of: "\u{2019}", with: "'")   // ' right single
            .replacingOccurrences(of: "\u{201A}", with: "'")   // ‚ low single
            .replacingOccurrences(of: "\u{201B}", with: "'")   // ‛ reversed single
            .replacingOccurrences(of: "\u{201C}", with: "\"")  // " left double
            .replacingOccurrences(of: "\u{201D}", with: "\"")  // " right double
            .replacingOccurrences(of: "\u{201E}", with: "\"")  // „ low double
            .replacingOccurrences(of: "\u{201F}", with: "\"")  // ‟ reversed double
    }
}
