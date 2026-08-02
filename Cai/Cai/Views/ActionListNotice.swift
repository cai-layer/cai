import Foundation

/// The one notice the action list may show above its content.
///
/// Three things compete for that strip: agent proposals waiting for review, an
/// available update, and the crash-reporting opt-in. Only one can show, so the
/// priority lives here as a pure function rather than as a chain of negations
/// growing inside the view (`if !crashPromptShown && !updateAvailable && ...`),
/// which is what it had started to become.
///
/// Order is by how much the user loses by missing it: a proposal is something
/// they asked an agent for and cannot run until they approve it, an update can
/// wait for the next launch, and the crash prompt can wait forever.
enum ActionListNotice: Equatable {
    case proposals(count: Int)
    case update
    case crashReporting

    static func active(
        pendingProposals: Int,
        updateAvailable: Bool,
        crashPromptShown: Bool
    ) -> ActionListNotice? {
        if pendingProposals > 0 { return .proposals(count: pendingProposals) }
        if updateAvailable { return .update }
        if !crashPromptShown { return .crashReporting }
        return nil
    }

    var icon: String {
        switch self {
        case .proposals: return "tray.and.arrow.down"
        case .update: return "arrow.down.circle"
        case .crashReporting: return "ladybug"
        }
    }

    var message: String {
        switch self {
        case .proposals(let count):
            // "Proposed action" rather than "proposal": it is the noun the
            // menu item, the sheet title and the arrival toast already use,
            // and "proposal" on its own does not say what is being proposed.
            return count == 1 ? "1 proposed action waiting" : "\(count) proposed actions waiting"
        case .update:
            return "A new version of Cai is available"
        case .crashReporting:
            return "Send anonymous crash reports?"
        }
    }

    /// Title of the affirmative button.
    var actionTitle: String {
        switch self {
        case .proposals: return "Review"
        case .update: return "Update"
        case .crashReporting: return "Enable"
        }
    }

    /// Title of the dismissive button, when the notice has one. Proposals and
    /// updates do not: neither is dismissed from here, they are dealt with on
    /// their own surface.
    var declineTitle: String? {
        switch self {
        case .proposals, .update: return nil
        case .crashReporting: return "Nope"
        }
    }
}
