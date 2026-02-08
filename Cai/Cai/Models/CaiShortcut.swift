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

    enum ShortcutType: String, Codable, CaseIterable {
        case prompt
        case url

        var icon: String {
            switch self {
            case .prompt: return "bolt.circle.fill"
            case .url: return "safari.fill"
            }
        }

        var label: String {
            switch self {
            case .prompt: return "Prompt"
            case .url: return "URL"
            }
        }

        var placeholder: String {
            switch self {
            case .prompt: return "e.g. Rewrite as a professional email reply"
            case .url: return "e.g. https://www.reddit.com/search/?q=%s"
            }
        }
    }

    init(id: UUID = UUID(), name: String, type: ShortcutType, value: String) {
        self.id = id
        self.name = name
        self.type = type
        self.value = value
    }
}
