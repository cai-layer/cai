import Foundation

/// How much friction the approval sheet puts in front of an action.
public enum ApprovalTier: String, Codable, Equatable, Sendable {
    /// Prompt action, no flags, no executable chain: name, payload, approve.
    case standard
    /// Anything that can run code, reach the network, or change the user's
    /// text without review. Warning styling plus an acknowledgment checkbox
    /// that gates the Approve button.
    case escalated
}

/// Why an action escalated. One case per callout in the approval sheet; PR 2
/// maps these to the exact copy strings from the design spec.
public enum EscalationReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// Shell action, or a chain touching a shell / AppleScript destination or
    /// an Apple Shortcut.
    case runsShellCommands
    /// URL action, or a chain touching a webhook or deeplink destination.
    case sendsSelectionToURL
    /// `autoReplaceSelection`, or a chain ending in Replace Selection.
    case replacesSelection
    /// `runInBackground`.
    case runsWithoutShowingOutput
    /// A chain step naming an action that resolves to nothing. It runs
    /// nothing today, but the name can be claimed by a later proposal: approve
    /// this with one click, then approve a shell action carrying that name,
    /// and this action reaches shell without its callout ever appearing. The
    /// risk is the blind handoff, so it escalates now, while the user is
    /// looking.
    case chainsToUnknownAction
    /// A template reaches for a `{{secrets.NAME}}` reference. No associated
    /// names: this enum is `String`-raw `Codable` and persisted with
    /// proposals, so the sheet re-scans the templates at render time for the
    /// names — which also means the callout can never show names computed
    /// from a stale validation (CAI-25).
    case referencesSecrets
}

public enum ApprovalClassifier {

    /// Classifies an action, following its chain into referenced actions.
    ///
    /// Chains are followed because the payload the user reads has to account
    /// for what the action actually triggers: a prompt action whose chain ends
    /// in a shell destination runs shell. The traversal itself lives in
    /// `ChainWalk.reachable(from:known:)` — resolution order, breadth-first
    /// depth capping and the id-keyed visited set are documented there, and
    /// `CapabilityDetector` folds over the same walk so the chips and the
    /// callouts can never describe different chains.
    ///
    /// Reasons come back in `EscalationReason.allCases` order so the sheet
    /// renders callouts in a stable sequence and table tests can compare
    /// arrays directly.
    public static func escalationReasons(
        for action: ActionSnapshot,
        known: KnownActions
    ) -> [EscalationReason] {
        var found: Set<EscalationReason> = []
        let reach = ChainWalk.reachable(from: action, known: known)

        for (current, _) in reach.actions {
            if current.type == .shell { found.insert(.runsShellCommands) }
            if current.type == .url { found.insert(.sendsSelectionToURL) }
            if current.autoReplaceSelection { found.insert(.replacesSelection) }
            if current.runInBackground { found.insert(.runsWithoutShowingOutput) }
            // The advisory scanner, not the engine's parser: over-reporting
            // here makes a proposal look slightly scarier, never less scary,
            // and execution resolves names through the engine regardless.
            if SecretReference.referencesAnySecret(current.value) {
                found.insert(.referencesSecrets)
            }
        }

        for leaf in reach.leaves {
            switch leaf {
            case .appleShortcut:
                // `shortcuts run` launches a user workflow through a
                // subprocess. Cai cannot see what it does, so it escalates
                // with the executable callout rather than passing silently.
                found.insert(.runsShellCommands)
            case .destination(let destination):
                switch destination.kind {
                case .shell, .applescript:
                    found.insert(.runsShellCommands)
                case .webhook, .deeplink:
                    found.insert(.sendsSelectionToURL)
                case .pasteBack:
                    found.insert(.replacesSelection)
                case .clipboardCopy:
                    continue
                }
            case .builtIn:
                // Built-ins are leaf LLM transforms.
                continue
            case .unresolved:
                // Runs nothing today, but "today" is when the user is
                // deciding: a later proposal can claim the name and this action
                // starts reaching whatever it does. The unresolved-step warning
                // still names the steps; this is what makes the approval a
                // deliberate act.
                found.insert(.chainsToUnknownAction)
            }
        }

        return EscalationReason.allCases.filter { found.contains($0) }
    }

    public static func tier(for action: ActionSnapshot, known: KnownActions) -> ApprovalTier {
        escalationReasons(for: action, known: known).isEmpty ? .standard : .escalated
    }
}
