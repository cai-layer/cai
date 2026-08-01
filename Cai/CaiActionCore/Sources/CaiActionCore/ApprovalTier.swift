import Foundation

/// How much friction the approval sheet puts in front of an action.
public enum ApprovalTier: String, Codable, Equatable, Sendable {
    /// Prompt action, no flags, no executable chain: name, payload, approve.
    case standard
    /// Anything that can run code, reach the network, or change the user's
    /// text without review. Warning styling plus a per-type acknowledgment
    /// checkbox that gates the Approve button.
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
}

public enum ApprovalClassifier {

    /// Classifies an action, following its chain into referenced actions.
    ///
    /// Chains are followed because the payload the user reads has to account
    /// for what the action actually triggers: a prompt action whose chain ends
    /// in a shell destination runs shell. Resolution order matches
    /// `ChainExecutor`, and a visited set plus the step cap stop a cyclic or
    /// runaway chain from spinning here.
    ///
    /// Reasons come back in `EscalationReason.allCases` order so the sheet
    /// renders callouts in a stable sequence and table tests can compare
    /// arrays directly.
    public static func escalationReasons(
        for action: ActionSnapshot,
        known: KnownActions
    ) -> [EscalationReason] {
        var found: Set<EscalationReason> = []
        collect(into: &found, action: action, known: known, visited: [action.name], depth: 0)
        return EscalationReason.allCases.filter { found.contains($0) }
    }

    public static func tier(for action: ActionSnapshot, known: KnownActions) -> ApprovalTier {
        escalationReasons(for: action, known: known).isEmpty ? .standard : .escalated
    }

    private static func collect(
        into found: inout Set<EscalationReason>,
        action: ActionSnapshot,
        known: KnownActions,
        visited: Set<String>,
        depth: Int
    ) {
        if action.type == .shell { found.insert(.runsShellCommands) }
        if action.type == .url { found.insert(.sendsSelectionToURL) }
        if action.autoReplaceSelection { found.insert(.replacesSelection) }
        if action.runInBackground { found.insert(.runsWithoutShowingOutput) }

        guard depth < ActionSchema.maxChainSteps else { return }

        for step in action.next {
            switch step {
            case .inlineLLM:
                continue
            case .appleShortcut:
                // `shortcuts run` launches a user workflow through a
                // subprocess. Cai cannot see what it does, so it escalates
                // with the executable callout rather than passing silently.
                found.insert(.runsShellCommands)
            case .action(let name):
                guard !visited.contains(name) else { continue }
                switch known.resolveChainName(name) {
                case .shortcut(let referenced):
                    collect(
                        into: &found,
                        action: referenced,
                        known: known,
                        visited: visited.union([name]),
                        depth: depth + 1
                    )
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
                case .builtIn, .unresolved:
                    // Built-ins are leaf LLM transforms. An unresolved name
                    // runs nothing at all; it surfaces as a warning instead.
                    continue
                }
            }
        }
    }
}
