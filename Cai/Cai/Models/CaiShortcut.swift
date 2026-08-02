import CaiActionCore
import Foundation

// MARK: - Custom Shortcut Model

/// A user-defined shortcut that appears when typing to filter the action list.
/// Two types: prompt (sends clipboard text + saved prompt to LLM) and url
/// (opens a URL template with clipboard text substituted for %s).
struct CaiShortcut: Codable, Identifiable, Equatable {
    /// The type enum lives in `CaiActionCore` so the validator and the
    /// `cai-mcp` helper speak the same one. Raw values are unchanged, so
    /// shortcuts persisted by earlier versions decode as before.
    typealias ShortcutType = CaiActionType

    let id: UUID
    var name: String
    var type: ShortcutType
    var value: String  // prompt text or URL template with %s
    /// When true (prompt-type only), the LLM response is pasted straight over
    /// the user's current selection in the source app, skipping the result
    /// review UI. Defaults to false.
    var autoReplaceSelection: Bool
    /// When true, this shortcut appears at the top of the default action list
    /// (above built-ins) and consumes the first ⌘ numbers.
    var pinned: Bool
    /// When true (shell-type only), the action dismisses Cai immediately and
    /// runs the shell command in the background, surfacing completion or error
    /// via a toast. Useful for slow `|llm`-containing templates and for
    /// fire-and-forget actions like `say` / Slack webhooks where the user
    /// doesn't need to see the output. Defaults to false.
    /// The shortcut editor auto-enables this flag on transition from "no `|llm`"
    /// to "has `|llm`" in the template (one-shot heuristic; user can override).
    var runInBackground: Bool
    /// Chain steps to run after this action completes. Sequential pipe —
    /// each step's output becomes the next step's `{{result}}`. NOT routed
    /// through the system clipboard: the chain executor uses an in-memory
    /// pipe so the user can copy other text mid-chain without breaking the
    /// flow. Empty array means "no chaining" (the default).
    /// Steps can be Cai actions (by name), inline LLM directives, or Apple
    /// Shortcuts (by name) — see `ChainStep`. Cycle detection + max-depth-10
    /// guard the executor against runaway loops.
    var next: [ChainStep]
    /// Who authored this shortcut and when, when it did not come from the
    /// user's own hands. Set for actions approved from an agent proposal and
    /// carried forever after, so the shortcuts list can badge them with "via
    /// Claude Code". `nil` for everything a user created in the editor, which
    /// is also what every already-stored shortcut decodes to.
    var provenance: ActionProvenance?

    init(id: UUID = UUID(), name: String, type: ShortcutType, value: String, autoReplaceSelection: Bool = false, pinned: Bool = false, runInBackground: Bool = false, next: [ChainStep] = [], provenance: ActionProvenance? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.value = value
        self.autoReplaceSelection = autoReplaceSelection
        self.pinned = pinned
        self.runInBackground = runInBackground
        self.next = next
        self.provenance = provenance
    }

    // Custom decoder so previously-persisted shortcuts (without newer flags)
    // still decode, defaulting them to false / empty / nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(ShortcutType.self, forKey: .type)
        self.value = try c.decode(String.self, forKey: .value)
        self.autoReplaceSelection = try c.decodeIfPresent(Bool.self, forKey: .autoReplaceSelection) ?? false
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.runInBackground = try c.decodeIfPresent(Bool.self, forKey: .runInBackground) ?? false
        self.next = try c.decodeIfPresent([ChainStep].self, forKey: .next) ?? []
        self.provenance = try c.decodeIfPresent(ActionProvenance.self, forKey: .provenance)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, value, autoReplaceSelection, pinned, runInBackground, next, provenance
    }
}

// MARK: - Action Type Presentation
//
// The type itself is shared with the helper via CaiActionCore; how it looks in
// the shortcuts editor is the app's business and stays here.

extension CaiActionType {

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
        // Bare `{{result}}` is safe by default in shell templates — Cai
        // escapes via the |shell filter automatically. No surrounding
        // quotes needed.
        case .shell: return "e.g. echo {{result}} | base64 -D"
        }
    }
}

// MARK: - CaiActionCore Bridging

extension CaiShortcut {

    /// The shortcut as the validator and the helper see it. Provenance is
    /// deliberately not part of the snapshot: it describes where the action
    /// came from, not what it does, and an agent has no business patching it.
    var actionSnapshot: ActionSnapshot {
        ActionSnapshot(
            id: id,
            name: name,
            type: type,
            value: value,
            autoReplaceSelection: autoReplaceSelection,
            runInBackground: runInBackground,
            pinned: pinned,
            next: next
        )
    }

    init(snapshot: ActionSnapshot, provenance: ActionProvenance?) {
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            type: snapshot.type,
            value: snapshot.value,
            autoReplaceSelection: snapshot.autoReplaceSelection,
            pinned: snapshot.pinned,
            runInBackground: snapshot.runInBackground,
            next: snapshot.next,
            provenance: provenance
        )
    }
}
