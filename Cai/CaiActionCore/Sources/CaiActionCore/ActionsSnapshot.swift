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
///
/// Secret *names* are present (`secretNames`) so an agent references the one
/// the user actually stored instead of guessing (`NOTION_TOKEN` for a secret
/// named `NOTION_API`). Values are never here — the same names already surface
/// through any existing action's template, and the value is unreadable to the
/// helper regardless.
public struct ActionsSnapshot: Codable, Equatable, Sendable {

    public let schemaVersion: Int
    public let generatedAt: Date
    public let actions: [ActionSnapshot]
    public let destinations: [DestinationSummary]
    /// Display labels of chainable built-in actions.
    public let builtInActionNames: [String]
    /// Names of the secrets stored on this Mac, sorted. Names only, never
    /// values — so an agent can write the right `{{secrets.NAME}}` reference.
    public let secretNames: [String]
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
        secretNames: [String] = [],
        agentAuthoringEnabled: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.actions = actions
        self.destinations = destinations
        self.builtInActionNames = builtInActionNames
        self.secretNames = secretNames
        self.agentAuthoringEnabled = agentAuthoringEnabled
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, actions, destinations
        case builtInActionNames, secretNames, agentAuthoringEnabled
    }

    /// Hand-rolled only so `secretNames` decodes as `[]` when absent. A snapshot
    /// written before this field existed still sits on disk right after an app
    /// update, until the new app relaunches and republishes; a synthesized
    /// decoder would throw `keyNotFound` on it and blank `list_actions` in the
    /// meantime. Everything else decodes exactly as the synthesis would.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        actions = try c.decode([ActionSnapshot].self, forKey: .actions)
        destinations = try c.decode([DestinationSummary].self, forKey: .destinations)
        builtInActionNames = try c.decode([String].self, forKey: .builtInActionNames)
        secretNames = try c.decodeIfPresent([String].self, forKey: .secretNames) ?? []
        agentAuthoringEnabled = try c.decode(Bool.self, forKey: .agentAuthoringEnabled)
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
