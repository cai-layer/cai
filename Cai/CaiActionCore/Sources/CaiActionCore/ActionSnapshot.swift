import Foundation

/// The fields of a custom action that authoring cares about.
///
/// A neutral value type: the app maps `CaiShortcut` to and from it, the helper
/// reads it out of `actions-snapshot.json`, and the validator works only on
/// this. Nothing in CaiActionCore knows the app's model types.
public struct ActionSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var type: CaiActionType
    public var value: String
    public var autoReplaceSelection: Bool
    public var runInBackground: Bool
    public var pinned: Bool
    public var next: [ChainStep]

    public init(
        id: UUID,
        name: String,
        type: CaiActionType,
        value: String,
        autoReplaceSelection: Bool = false,
        runInBackground: Bool = false,
        pinned: Bool = false,
        next: [ChainStep] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.value = value
        self.autoReplaceSelection = autoReplaceSelection
        self.runInBackground = runInBackground
        self.pinned = pinned
        self.next = next
    }
}

/// A field of an action that a patch can touch. The raw values are the wire
/// names an agent uses in `update_action`, and the strings the approval sheet
/// labels a diff row with.
public enum ActionField: String, Codable, CaseIterable, Equatable, Sendable {
    case name
    case type
    case value
    case autoReplaceSelection
    case runInBackground
    case pinned
    case next
}

extension ActionSnapshot {

    /// Renders one field as the string used in mismatch errors and diff rows.
    /// Chains render as their step labels joined by arrows, matching how
    /// `ChainExecutor` reports a chain path.
    public func rendered(_ field: ActionField) -> String {
        switch field {
        case .name: return name
        case .type: return type.rawValue
        case .value: return value
        case .autoReplaceSelection: return String(autoReplaceSelection)
        case .runInBackground: return String(runInBackground)
        case .pinned: return String(pinned)
        case .next: return ActionSnapshot.renderChain(next)
        }
    }

    public static func renderChain(_ steps: [ChainStep]) -> String {
        steps.map(\.displayLabel).joined(separator: " → ")
    }
}

/// What a destination is, without its configuration.
///
/// The approval sheet needs to know that a chain step named "Slack" posts to a
/// webhook so it can escalate, but it must never carry the webhook URL or its
/// headers into the authoring surface: destination configs stay in the app.
public struct DestinationSummary: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Equatable, Sendable {
        case applescript
        case webhook
        case deeplink
        case shell
        case pasteBack
        case clipboardCopy
        case showInCai
    }

    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// Everything already installed on this Mac that an authored action can
/// collide with or reference. Built by the app from `CaiSettings` and handed
/// to the validator; the validator never reaches for global state.
public struct KnownActions: Equatable, Sendable {
    public let shortcuts: [ActionSnapshot]
    public let destinations: [DestinationSummary]
    /// Display labels of chainable built-in actions (Summarize, Explain, …).
    public let builtInActionNames: [String]

    public init(
        shortcuts: [ActionSnapshot] = [],
        destinations: [DestinationSummary] = [],
        builtInActionNames: [String] = []
    ) {
        self.shortcuts = shortcuts
        self.destinations = destinations
        self.builtInActionNames = builtInActionNames
    }
}
