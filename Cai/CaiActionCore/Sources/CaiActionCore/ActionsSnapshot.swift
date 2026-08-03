import Foundation

/// What the app publishes about itself for the helper to read.
///
/// The helper has no way to ask the app anything: there is no socket and no
/// port, by design. So the app writes this file on every change to its
/// actions, and the helper reads it to answer `list_actions`, to fill in the
/// `expected` values an update needs, and to validate a proposal before
/// writing it.
///
/// **What is deliberately absent:** destination configuration. A webhook's URL
/// and headers can carry credentials, and nothing about authoring needs them.
/// Names and kinds are enough to resolve a chain step and to tell the user
/// what an action will reach.
public struct ActionsSnapshot: Codable, Equatable, Sendable {

    public let schemaVersion: Int
    public let generatedAt: Date
    public let actions: [ActionSnapshot]
    public let destinations: [DestinationSummary]
    /// Display labels of chainable built-in actions.
    public let builtInActionNames: [String]
    /// The kill switch. When false the helper refuses to write anything, so an
    /// agent gets a clear error instead of proposals that queue into a
    /// directory the app has stopped watching.
    public let agentAuthoringEnabled: Bool

    public init(
        schemaVersion: Int = ActionSchema.version,
        generatedAt: Date,
        actions: [ActionSnapshot],
        destinations: [DestinationSummary],
        builtInActionNames: [String],
        agentAuthoringEnabled: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.actions = actions
        self.destinations = destinations
        self.builtInActionNames = builtInActionNames
        self.agentAuthoringEnabled = agentAuthoringEnabled
    }

    /// The same view of the world the app validates against, so the helper's
    /// verdict matches the app's for the same proposal.
    public var knownActions: KnownActions {
        KnownActions(
            shortcuts: actions,
            destinations: destinations,
            builtInActionNames: builtInActionNames
        )
    }
}
