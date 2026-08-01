import Foundation

/// What a `.action(name:)` chain step points at.
public enum ResolvedChainTarget: Equatable, Sendable {
    case shortcut(ActionSnapshot)
    case destination(DestinationSummary)
    case builtIn(String)
    case unresolved
}

extension KnownActions {

    /// Resolves a chain step name the same way `ChainExecutor.resolve(_:)`
    /// does at runtime: user shortcuts win, then destinations, then chainable
    /// built-ins. Kept in lockstep with the executor deliberately — the
    /// approval sheet must describe the action that will actually run, not a
    /// different resolution order.
    public func resolveChainName(_ name: String) -> ResolvedChainTarget {
        if let shortcut = shortcuts.first(where: { $0.name == name }) {
            return .shortcut(shortcut)
        }
        if let destination = destinations.first(where: { $0.name == name }) {
            return .destination(destination)
        }
        if let builtIn = builtInActionNames.first(where: { $0 == name }) {
            return .builtIn(builtIn)
        }
        return .unresolved
    }

    /// Names of `.action(name:)` chain steps that don't resolve to anything
    /// installed locally. Used to flag chains whose dependencies are missing,
    /// both for extension installs and for agent-authored actions.
    ///
    /// Apple Shortcuts and inline LLM steps are intentionally not checked:
    /// - `.appleShortcut`: querying Shortcuts.app is async and brittle; let
    ///   the runtime surface a clear error if it's missing
    /// - `.inlineLLM`: always resolvable (only requires LLM configured)
    ///
    /// Pure and nonisolated so the app's `CaiSettings.unresolvedChainSteps`
    /// and the validator share one answer.
    public func unresolvedChainStepNames(in steps: [ChainStep]) -> [String] {
        steps.compactMap { step in
            guard case .action(let name) = step else { return nil }
            return resolveChainName(name) == .unresolved ? name : nil
        }
    }
}

public enum ChainResolution {

    /// Name-set form of `KnownActions.unresolvedChainStepNames(in:)`, for
    /// callers that already have names and must not pay to build snapshots.
    /// The management lists call this once per row on every hover, so the
    /// no-chain case has to allocate nothing at all.
    public static func unresolvedChainStepNames(
        in steps: [ChainStep],
        knownNames: @autoclosure () -> Set<String>
    ) -> [String] {
        guard steps.contains(where: { if case .action = $0 { return true } else { return false } }) else {
            return []
        }
        let names = knownNames()
        return steps.compactMap { step in
            guard case .action(let name) = step else { return nil }
            return names.contains(name) ? nil : name
        }
    }
}
