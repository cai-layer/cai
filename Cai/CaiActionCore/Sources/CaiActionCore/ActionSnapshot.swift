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

/// One of Cai's own built-in destinations, identified by role rather than by
/// name.
///
/// The app maps its fixed built-in UUIDs onto these; nothing here is derived
/// from a destination's display name. That matters: names are user-editable and
/// not unique, so a user-authored AppleScript destination named "Save to Notes"
/// would otherwise borrow the built-in's chip and claim Cai vouches for what it
/// does. Identity, never a label.
public enum BuiltInDestinationRole: String, Codable, Equatable, Sendable {
    case mailDraft
    case notes
    case reminders
    case replaceSelection
    case clipboard
    /// Ends a chain by putting its output on screen in Cai. Consumes nothing
    /// and reaches nothing outside the app.
    case showInCai
}

/// What a destination is, without its configuration.
///
/// The approval sheet needs to know that a chain step named "Slack" posts to a
/// webhook so it can escalate, but it must never carry the webhook URL or its
/// headers into the authoring surface: destination configs stay in the app.
///
/// `networkTarget` and `builtInRole` are enrichment for capability chips, and
/// they are deliberately **not Codable**. `ActionsSnapshot` publishes
/// `[DestinationSummary]` to `actions-snapshot.json`, which the helper reads and
/// an agent therefore sees; a hostname like `hooks.internal.acme.com` is mildly
/// identifying and nothing about authoring needs it. So the coded shape stays
/// exactly `name` + `kind`, as before, and the two enrichment fields exist only
/// in the app's own process, where the chips are rendered. A decoded summary
/// carries nil for both, which is the honest answer for the helper: it draws no
/// chips.
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

    /// Where this destination reaches on the network, host-only for a
    /// `.webhook` and scheme-only for a `.deeplink`. Nil when the destination
    /// does not reach the network, or when its URL is templated and so cannot
    /// be resolved without guessing.
    ///
    /// Host-only is the point. For a Slack incoming webhook the *path* is the
    /// credential and the host is public, so carrying the host and dropping
    /// everything else is a stricter rule than "no configs", not a looser one.
    public let networkTarget: String?

    /// Set only for Cai's own built-in destinations, by UUID in the app. Nil
    /// for everything a user or an extension authored.
    public let builtInRole: BuiltInDestinationRole?

    public init(
        name: String,
        kind: Kind,
        networkTarget: String? = nil,
        builtInRole: BuiltInDestinationRole? = nil
    ) {
        self.name = name
        self.kind = kind
        self.networkTarget = networkTarget
        self.builtInRole = builtInRole
    }

    // MARK: - Codable

    /// Name and kind only, both directions. See the type's note: the coded
    /// shape is agent-visible and the enrichment fields are not for it.
    enum CodingKeys: String, CodingKey {
        case name, kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        networkTarget = nil
        builtInRole = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
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
