import Foundation

/// One thing an action will touch, as Cai can vouch for it.
///
/// The vocabulary is deliberately small and closed. A case exists only where
/// Cai derives the fact from the action itself: its type, its resolved chain,
/// its secret references, or a URL it can parse without guessing. Nothing here
/// comes from an agent's prose, and nothing is a model's summary of a payload —
/// a description on an approval surface must be something the surface can
/// vouch for, or it becomes a friendly sentence that disagrees with the code.
/// This is the macOS model: the system says "wants to access your Contacts"
/// from the entitlement, not from the app's marketing copy.
///
/// Capabilities are an unordered bag rendered in a fixed order. They say what
/// an action reaches, NOT the sequence it reaches things in; the numbered chain
/// block on the approval sheet remains the ordered evidence, and it must not be
/// "simplified" away on the grounds that the chips cover it.
public enum Capability: Equatable, Hashable, Sendable {

    /// A freeform shell body. The honest floor: Cai cannot bound what a command
    /// does, and says so rather than implying a complete list.
    case runsShellCommand
    /// A user-authored AppleScript destination. Same unbounded shape as shell.
    case runsAppleScript
    /// `shortcuts run` on a user workflow Cai cannot see into.
    case runsAppleShortcut
    /// A chain step naming something not installed. Runs nothing today, but the
    /// name can be claimed later, so it is never hidden.
    case runsUninstalled(name: String)

    /// The selection leaves the Mac for this host: a webhook destination, or a
    /// url action whose template embeds the selection.
    case sendsToHost(String)
    /// A url action that opens a fixed address, selection not embedded.
    case opensHost(String)
    /// A deeplink destination, by scheme. A deeplink has no meaningful host to
    /// vouch for, so the scheme is all that is claimed.
    case opensScheme(String)

    /// A `{{secrets.NAME}}` reference. The name, never the value.
    case usesSecret(name: String)

    /// A model runs: a prompt action, an inline LLM step, or a built-in
    /// transform. Whether that is on-device or a cloud provider is
    /// privacy-relevant and is folded into the label at render time, because the
    /// configured engine is app state and not a property of the action.
    case runsAI

    case opensMailDraft
    /// A built-in that writes into a named Apple app: Notes, Reminders.
    case writesTo(app: String)
    case replacesSelection
    case copiesToClipboard

    /// Whether this capability means the list it belongs to cannot be complete.
    ///
    /// Derived, never stored. An earlier draft returned the capabilities beside
    /// a stored `isExhaustive` flag, which is redundant state two call sites can
    /// desync — and a chip row that wrongly claims completeness is the exact
    /// false reassurance this feature exists to avoid. Computed from the list,
    /// the desync is unrepresentable.
    public var isOpenEnded: Bool {
        switch self {
        case .runsShellCommand, .runsAppleScript, .runsAppleShortcut, .runsUninstalled:
            return true
        default:
            return false
        }
    }

    /// Fixed render order, most consequential first, so the same action always
    /// draws the same row in the same sequence.
    ///
    /// Two properties this ordering has to keep. Open-ended capabilities sort
    /// first, so a compact row that shows only its first few chips can never cut
    /// the honest floor — that invariant, not the "+N" suffix, is what keeps a
    /// truncated row honest. And secrets rank directly after the network group:
    /// in a top-three cut, "Uses SLACK_WEBHOOK" losing its slot to "Replaces
    /// your selection" is the wrong loser.
    var sortOrder: Int {
        switch self {
        case .runsShellCommand: return 0
        case .runsAppleScript: return 1
        case .runsAppleShortcut: return 2
        case .runsUninstalled: return 3
        case .sendsToHost: return 4
        case .opensScheme: return 5
        case .opensHost: return 6
        case .usesSecret: return 7
        case .runsAI: return 8
        case .opensMailDraft: return 9
        case .writesTo: return 10
        case .replacesSelection: return 11
        case .copiesToClipboard: return 12
        }
    }

    /// Secondary sort within a case that can repeat, so two secrets or two
    /// hosts render in a stable order rather than in dictionary order.
    var sortKey: String {
        switch self {
        case .runsUninstalled(let name): return name
        case .sendsToHost(let host), .opensHost(let host): return host
        case .opensScheme(let scheme): return scheme
        case .usesSecret(let name): return name
        case .writesTo(let app): return app
        default: return ""
        }
    }
}

extension Array where Element == Capability {

    /// Whether this list accounts for everything the action does.
    ///
    /// False as soon as any member is open-ended. The UI states its own limits
    /// when this is false; it never renders a bounded-looking row over an
    /// unbounded action.
    public var isExhaustive: Bool { !contains(where: \.isOpenEnded) }
}
