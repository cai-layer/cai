import Foundation

// MARK: - Context Snippet

/// A per-app system prompt enrichment. When the user triggers an LLM action
/// and the frontmost app's bundleId matches, this snippet is injected into
/// the LLM system prompt as a structured `[App context: {appName}]` section.
///
/// Example — a user with a Terminal snippet configured:
///   "When I copy from Terminal, I'm usually debugging a Rails app."
/// …sees every LLM action from Terminal enriched with that context.
///
/// **Design notes:**
/// - `bundleId` is the canonical match key (stable across machines, languages, app rebrands)
/// - `appName` is display-hint metadata only (for UI / help docs / "App context" header)
/// - `id` is unused in v1 (no CRUD) but kept for v1.1 SwiftUI diffing / Settings UI
/// - `Equatable` is auto-synthesized and unlocks v1.1 `ForEach` identity tracking
struct ContextSnippet: Codable, Identifiable, Equatable {
    var id: UUID
    var bundleId: String
    var appName: String
    var context: String
    var enabled: Bool

    init(id: UUID = UUID(), bundleId: String, appName: String, context: String, enabled: Bool = true) {
        self.id = id
        self.bundleId = bundleId
        self.appName = appName
        self.context = context
        self.enabled = enabled
    }

    /// Advisory maximum length for the context string. Not enforced at the model level —
    /// v1.1 Settings UI will show a char counter, and the 50K-char LLM input cap in
    /// `LLMService.truncateMessages` provides a hard safety net.
    static let maxContextLength = 500
}

// MARK: - JSON File Envelope

/// On-disk JSON envelope for `~/.config/cai/snippets.json`. Includes a `version`
/// field so future schema changes can be migrated cleanly.
///
/// Designed to be portable: a future Settings Export/Import feature will embed
/// this struct verbatim inside a larger `cai-settings.json` blob. No timestamps,
/// no machine-specific paths, no local-only fields.
struct ContextSnippetsFile: Codable {
    /// Schema version. Always `1` in this PR. Future versions will migrate
    /// on load (or reject with a clear error if downgrading).
    var version: Int

    /// All configured snippets. Empty array is a valid state.
    var snippets: [ContextSnippet]
}
