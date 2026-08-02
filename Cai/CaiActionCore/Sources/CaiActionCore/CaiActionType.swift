import Foundation

/// The three kinds of custom action a user (or their agent) can author.
///
/// Moved here from `CaiShortcut.ShortcutType` so the helper, the validator and
/// the app all speak one enum. Raw values are unchanged, so shortcuts already
/// persisted in UserDefaults keep decoding. The app keeps
/// `CaiShortcut.ShortcutType` as a typealias and hangs its UI affordances
/// (icon, label, placeholder) off this type in an extension.
public enum CaiActionType: String, Codable, CaseIterable, Equatable, Sendable {
    /// Sends the selection plus a saved prompt to the configured LLM.
    case prompt
    /// Opens a URL template with the selection substituted for `%s`.
    case url
    /// Runs a shell template. Executable: always an escalated approval.
    case shell

    /// True when merely approving this type hands an authored action the
    /// ability to run code or reach the network on the user's behalf. Drives
    /// the escalated approval tier; see `ApprovalTier`.
    public var isExecutable: Bool {
        switch self {
        case .prompt: return false
        case .url, .shell: return true
        }
    }
}
