import Foundation

/// One step in a chain (`CaiShortcut.next` / `OutputDestination.next`).
///
/// Moved from `Cai/Cai/Models/ChainStep.swift` into CaiActionCore so the
/// helper, the validator and the app share one definition. The Codable shape
/// is unchanged (auto-synthesized), so chains already persisted in
/// UserDefaults decode exactly as before.
///
/// **Cases:**
/// - `.action(name:)` — references an existing `CaiShortcut` or
///   `OutputDestination` by name. Lookup happens at execute time in
///   `ChainExecutor.resolve(_:)`. Shortcuts win on collision with destinations.
/// - `.inlineLLM(directive:)` — runs the chain pipe value through the local
///   LLM with `directive` as the system prompt. Reuses `LLMService.buildMessages`
///   so "About You" + per-app Context Snippets are injected consistently with
///   prompt-type shortcuts.
/// - `.appleShortcut(name:)` — invokes a user-authored Apple Shortcuts.app
///   shortcut by name via the `/usr/bin/shortcuts run` CLI. The chain pipe
///   value is passed via stdin (Shortcuts that accept text input consume it;
///   ones that don't silently ignore it). Stdout flows back into the pipe.
///
/// **Codable:** auto-synthesized case-keyed shape: one single-key object per
/// step: `{"action": {"name": "..."}}`, `{"inlineLLM": {"directive": "..."}}`,
/// `{"appleShortcut": {"name": "..."}}`. This is the wire shape everywhere:
/// UserDefaults, pending-change files, and the MCP `next` parameter.
///
/// **Future:** `.mcpAction(presetId:)` is reserved for v1.8 once we design
/// "preset MCP actions" (saved partial-fill of an MCP form, e.g. "create
/// GitHub issue in cai/cai with the bug label").
public enum ChainStep: Codable, Equatable, Hashable, Sendable {
    case action(name: String)
    case inlineLLM(directive: String)
    case appleShortcut(name: String)

    /// Short label for chip rendering. Truncated by the UI.
    /// - `.action` → the action name
    /// - `.inlineLLM` → the directive (italic in chip render)
    /// - `.appleShortcut` → the shortcut name
    public var displayLabel: String {
        switch self {
        case .action(let name): return name
        case .inlineLLM(let directive): return directive
        case .appleShortcut(let name): return name
        }
    }

    /// True when the step has no meaningful content. Used by the editor to
    /// auto-remove inline-LLM chips whose directive is left empty after edit
    /// (matches NSTokenField / Linear pill convention: empty token = no token),
    /// and by the validator to reject an authored chain carrying a blank step.
    public var isEmpty: Bool {
        switch self {
        case .action(let name): return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .inlineLLM(let directive): return directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .appleShortcut(let name): return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Wire-facing tag used in rejection messages and the approval sheet, so
    /// the agent and the user see the same word for a step kind.
    public var kindLabel: String {
        switch self {
        case .action: return "action"
        case .inlineLLM: return "llm"
        case .appleShortcut: return "apple_shortcut"
        }
    }
}
