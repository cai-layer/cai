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
    /// The walk is a breadth-first traversal over reachable actions with one
    /// shared visited set, which pins down two properties at once:
    ///
    /// - **Linear cost.** `found` is a union over reachable actions, so each
    ///   action needs visiting exactly once. A per-path visited set (the
    ///   depth-first alternative) enumerates every simple path instead, and a
    ///   10-wide mesh of a dozen proposals is millions of paths walked on the
    ///   main actor, retriggered by every rescan of the pending directory.
    /// - **Correct depth capping.** Breadth-first reaches every action at its
    ///   MINIMAL depth, so an action cut off by the step cap is genuinely out
    ///   of reach within the cap on every route. Depth-first with a shared
    ///   set gets this wrong: a long route walked first can park an action in
    ///   `visited` with its chain uncounted, and the short route the executor
    ///   would actually run then skips it — an under-escalation.
    ///
    /// `visited` holds action ids, never names. Names are not unique: a
    /// proposal may be named the same as an installed action, and a name-keyed
    /// visited set would then skip the chain step that resolves to the OTHER
    /// action. A proposal named "Deploy" chaining to "Deploy" would read as a
    /// harmless prompt while `ChainExecutor` resolved that step to the user's
    /// existing shell action and ran it.
    public static func escalationReasons(
        for action: ActionSnapshot,
        known: KnownActions
    ) -> [EscalationReason] {
        var found: Set<EscalationReason> = []
        var visited: Set<UUID> = [action.id]
        var queue: [(action: ActionSnapshot, depth: Int)] = [(action, 0)]
        var head = 0

        while head < queue.count {
            let (current, depth) = queue[head]
            head += 1

            if current.type == .shell { found.insert(.runsShellCommands) }
            if current.type == .url { found.insert(.sendsSelectionToURL) }
            if current.autoReplaceSelection { found.insert(.replacesSelection) }
            if current.runInBackground { found.insert(.runsWithoutShowingOutput) }

            guard depth < ActionSchema.maxChainSteps else { continue }

            for step in current.next {
                switch step {
                case .inlineLLM:
                    continue
                case .appleShortcut:
                    // `shortcuts run` launches a user workflow through a
                    // subprocess. Cai cannot see what it does, so it escalates
                    // with the executable callout rather than passing silently.
                    found.insert(.runsShellCommands)
                case .action(let name):
                    switch known.resolveChainName(name) {
                    case .shortcut(let referenced):
                        // An action already queued contributes nothing new to
                        // the union, whether this step is a genuine cycle or a
                        // second route to the same node. A different action
                        // that happens to share a name is a different action,
                        // and its risks count.
                        guard !visited.contains(referenced.id) else { continue }
                        visited.insert(referenced.id)
                        queue.append((referenced, depth + 1))
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
                        // deciding: a later proposal can claim the name and
                        // this action starts reaching whatever it does. The
                        // unresolved-step warning still names the steps; this
                        // is what makes the approval a deliberate act.
                        found.insert(.chainsToUnknownAction)
                    }
                }
            }
        }

        return EscalationReason.allCases.filter { found.contains($0) }
    }

    public static func tier(for action: ActionSnapshot, known: KnownActions) -> ApprovalTier {
        escalationReasons(for: action, known: known).isEmpty ? .standard : .escalated
    }
}
