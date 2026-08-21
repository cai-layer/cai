import Foundation

/// Everything an action can reach by following its chain.
///
/// One traversal, two readers: `ApprovalClassifier.escalationReasons` folds it
/// into risk reasons, `CapabilityDetector` folds it into capability chips. They
/// used to be one walk and a plan for a second one, which is the bug this
/// feature exists to prevent: two hand-rolled walks over the same graph that
/// must agree forever, where disagreement means a chip row missing an effect the
/// action really has. Under-detection is false reassurance, so there is one walk.
///
/// A plain value, deliberately. No visitor, no fold closure, no generic over the
/// accumulator: callers iterate two arrays. The subtleties worth preserving live
/// in `reachable(from:known:)` and are documented there.
public struct ChainReach: Equatable, Sendable {

    /// A chain step that is not itself an action, so the walk stops there.
    public enum Leaf: Equatable, Sendable {
        case destination(DestinationSummary)
        case appleShortcut(name: String)
        case builtIn(name: String)
        /// A step naming something that resolves to nothing installed.
        case unresolved(name: String)
    }

    /// Every action reachable within the step cap, the starting action first,
    /// each paired with the minimal depth it was reached at.
    public let actions: [(action: ActionSnapshot, depth: Int)]

    /// Every non-action step reached, in traversal order. Duplicates are kept:
    /// two chain steps naming the same destination are two effects, and it is
    /// the reader's business whether that matters to it.
    public let leaves: [Leaf]

    public static func == (lhs: ChainReach, rhs: ChainReach) -> Bool {
        lhs.leaves == rhs.leaves
            && lhs.actions.count == rhs.actions.count
            && zip(lhs.actions, rhs.actions).allSatisfy { $0.action == $1.action && $0.depth == $1.depth }
    }
}

public enum ChainWalk {

    /// Walks an action's chain the way `ChainExecutor` would, and reports
    /// everything it reaches.
    ///
    /// Resolution order matches `ChainExecutor.resolve(_:)` via
    /// `KnownActions.resolveChainName`: user shortcuts, then destinations, then
    /// chainable built-ins. The approval surface must describe the action that
    /// will actually run, not a different resolution order.
    ///
    /// The walk is breadth-first over reachable actions with one shared visited
    /// set, which pins down two properties at once:
    ///
    /// - **Linear cost.** Each action is visited exactly once, so a 10-wide mesh
    ///   of a dozen proposals costs a dozen visits. A per-path visited set (the
    ///   depth-first alternative) enumerates every simple path instead, millions
    ///   of them, on the main actor, retriggered by every rescan of the pending
    ///   directory.
    /// - **Correct depth capping.** Breadth-first reaches every action at its
    ///   MINIMAL depth, so an action cut off by the cap is genuinely out of reach
    ///   within the cap on every route. Depth-first with a shared set gets this
    ///   wrong: a long route walked first parks an action in `visited` with its
    ///   chain uncounted, and the short route the executor would actually run
    ///   then skips it — an under-report, in the direction that hides risk.
    ///
    /// `visited` holds action ids, never names. Names are not unique: a proposal
    /// may be named the same as an installed action, and a name-keyed visited set
    /// would then skip the chain step that resolves to the OTHER one — a
    /// proposal could hide a shell action behind a step named after its own
    /// harmless prompt while `ChainExecutor` resolved that step to the user's
    /// existing shell action and ran it.
    public static func reachable(from action: ActionSnapshot, known: KnownActions) -> ChainReach {
        var actions: [(action: ActionSnapshot, depth: Int)] = []
        var leaves: [ChainReach.Leaf] = []
        var visited: Set<UUID> = [action.id]
        var queue: [(action: ActionSnapshot, depth: Int)] = [(action, 0)]
        var head = 0

        while head < queue.count {
            let (current, depth) = queue[head]
            head += 1
            actions.append((current, depth))

            guard depth < ActionSchema.maxChainSteps else { continue }

            for step in current.next {
                switch step {
                case .inlineLLM:
                    continue
                case .appleShortcut(let name):
                    leaves.append(.appleShortcut(name: name))
                case .action(let name):
                    switch known.resolveChainName(name) {
                    case .shortcut(let referenced):
                        // An action already queued contributes nothing new,
                        // whether this step is a genuine cycle or a second route
                        // to the same node. A different action that happens to
                        // share a name is a different action, and it counts.
                        guard !visited.contains(referenced.id) else { continue }
                        visited.insert(referenced.id)
                        queue.append((referenced, depth + 1))
                    case .destination(let destination):
                        leaves.append(.destination(destination))
                    case .builtIn(let name):
                        leaves.append(.builtIn(name: name))
                    case .unresolved:
                        leaves.append(.unresolved(name: name))
                    }
                }
            }
        }

        return ChainReach(actions: actions, leaves: leaves)
    }
}

extension ChainReach {

    /// Whether any reachable step is an inline LLM directive.
    ///
    /// `.inlineLLM` is not a leaf: it resolves to nothing and reaches nothing, so
    /// the walk skips it, but "this runs a model" is a capability. Asked of the
    /// walked actions rather than recorded during the walk, so `leaves` stays
    /// strictly "things a step pointed at".
    public var hasInlineLLMStep: Bool {
        actions.contains { $0.action.next.contains { step in
            if case .inlineLLM = step { return true }
            return false
        } }
    }
}
