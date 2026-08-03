import Foundation

/// One proposed change waiting for the user's approval.
///
/// This is the entire contract between the `cai-mcp` helper and the app: the
/// helper writes one of these per proposal to
/// `~/Library/Application Support/Cai/pending-changes/<uuid>.json` (atomically,
/// 0600) and the app picks it up with a directory watcher. There is no socket
/// and no port; the file IS the transport.
///
/// **Wire shape (create):**
/// ```json
/// {
///   "schemaVersion": 1,
///   "id": "6C1B...",
///   "createdAt": "2026-08-01T14:32:11Z",
///   "provenance": {"source": "mcp", "client": "Claude Code", "authoredAt": "2026-08-01T14:32:11Z"},
///   "op": "create",
///   "action": {"name": "File issue", "type": "shell", "value": "gh issue create ...", "runInBackground": true}
/// }
/// ```
///
/// **Wire shape (update):**
/// ```json
/// {
///   "schemaVersion": 1, "id": "...", "createdAt": "...", "provenance": {...},
///   "op": "update",
///   "targetId": "the action's UUID",
///   "changes":  {"value": "gh issue create --title short"},
///   "expected": {"value": "gh issue create --title a much longer one"}
/// }
/// ```
///
/// `expected` is filled in by the helper from the snapshot it read, not by the
/// agent: the `update_action` tool keeps the locked `{id, changes}` shape. It
/// exists so the app can refuse to clobber an action the user edited between
/// the agent's read and the user's approval (see
/// `ActionRejection.valueMismatch`).
public struct PendingChange: Equatable, Sendable {

    public enum Operation: Equatable, Sendable {
        case create(ActionDraft)
        case update(ActionUpdate)

        /// Wire tag, also used in audit lines and rejection reasons.
        public var wireName: String {
            switch self {
            case .create: return "create"
            case .update: return "update"
            }
        }
    }

    public let schemaVersion: Int
    /// Identifies the proposal (and names its file), not the action.
    public let id: UUID
    public let createdAt: Date
    public let provenance: ActionProvenance
    public let operation: Operation

    public init(
        schemaVersion: Int = ActionSchema.version,
        id: UUID,
        createdAt: Date,
        provenance: ActionProvenance,
        operation: Operation
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.provenance = provenance
        self.operation = operation
    }
}

// MARK: - Draft (create)

/// A brand new action, exactly as proposed. Flags default to false and the
/// chain to empty so an agent can send the three required fields and nothing
/// else.
public struct ActionDraft: Equatable, Sendable {
    public var name: String
    public var type: CaiActionType
    public var value: String
    public var autoReplaceSelection: Bool
    public var runInBackground: Bool
    public var pinned: Bool
    public var next: [ChainStep]

    public init(
        name: String,
        type: CaiActionType,
        value: String,
        autoReplaceSelection: Bool = false,
        runInBackground: Bool = false,
        pinned: Bool = false,
        next: [ChainStep] = []
    ) {
        self.name = name
        self.type = type
        self.value = value
        self.autoReplaceSelection = autoReplaceSelection
        self.runInBackground = runInBackground
        self.pinned = pinned
        self.next = next
    }

    /// The draft as it would be stored, given an id assigned at approval time.
    public func snapshot(id: UUID) -> ActionSnapshot {
        ActionSnapshot(
            id: id,
            name: name,
            type: type,
            value: value,
            autoReplaceSelection: autoReplaceSelection,
            runInBackground: runInBackground,
            pinned: pinned,
            next: next
        )
    }
}

// MARK: - Update (patch)

/// A patch against an existing action: only the fields that change travel.
public struct ActionUpdate: Equatable, Sendable {
    public let targetId: UUID
    public let changes: ActionPatch
    /// The values the helper read for every field in `changes`. Must cover the
    /// same fields, and must still match the live action at approval time.
    public let expected: ActionPatch

    public init(targetId: UUID, changes: ActionPatch, expected: ActionPatch) {
        self.targetId = targetId
        self.changes = changes
        self.expected = expected
    }
}

/// A sparse set of action fields. Used for both halves of an update (the new
/// values and the expected old ones).
public struct ActionPatch: Equatable, Sendable {
    public var name: String?
    public var type: CaiActionType?
    public var value: String?
    public var autoReplaceSelection: Bool?
    public var runInBackground: Bool?
    public var pinned: Bool?
    public var next: [ChainStep]?

    public init(
        name: String? = nil,
        type: CaiActionType? = nil,
        value: String? = nil,
        autoReplaceSelection: Bool? = nil,
        runInBackground: Bool? = nil,
        pinned: Bool? = nil,
        next: [ChainStep]? = nil
    ) {
        self.name = name
        self.type = type
        self.value = value
        self.autoReplaceSelection = autoReplaceSelection
        self.runInBackground = runInBackground
        self.pinned = pinned
        self.next = next
    }

    /// Fields present in this patch, in a stable order.
    public var fields: [ActionField] {
        ActionField.allCases.filter { contains($0) }
    }

    public var isEmpty: Bool { fields.isEmpty }

    public func contains(_ field: ActionField) -> Bool {
        switch field {
        case .name: return name != nil
        case .type: return type != nil
        case .value: return value != nil
        case .autoReplaceSelection: return autoReplaceSelection != nil
        case .runInBackground: return runInBackground != nil
        case .pinned: return pinned != nil
        case .next: return next != nil
        }
    }

    /// String form of one field, for mismatch errors and diff rows.
    public func rendered(_ field: ActionField) -> String? {
        switch field {
        case .name: return name
        case .type: return type?.rawValue
        case .value: return value
        case .autoReplaceSelection: return autoReplaceSelection.map(String.init)
        case .runInBackground: return runInBackground.map(String.init)
        case .pinned: return pinned.map(String.init)
        case .next: return next.map(ActionSnapshot.renderChain)
        }
    }

    /// True when this patch's value for `field` equals the action's current
    /// one. Comparison is typed, not string-based, so a chain reordering isn't
    /// mistaken for a no-op.
    public func matches(_ field: ActionField, in snapshot: ActionSnapshot) -> Bool {
        switch field {
        case .name: return name == snapshot.name
        case .type: return type == snapshot.type
        case .value: return value == snapshot.value
        case .autoReplaceSelection: return autoReplaceSelection == snapshot.autoReplaceSelection
        case .runInBackground: return runInBackground == snapshot.runInBackground
        case .pinned: return pinned == snapshot.pinned
        case .next: return next == snapshot.next
        }
    }

    /// The action's current values for exactly the fields this patch touches.
    ///
    /// This is what the helper attaches as `expected`, and it is why the
    /// agent-facing `update_action` stays `{id, changes}`: the agent says what
    /// it wants changed, the helper records what it saw when it read the
    /// action, and the app refuses the patch if the user has changed those
    /// fields in between.
    public func capturingCurrentValues(from snapshot: ActionSnapshot) -> ActionPatch {
        var expected = ActionPatch()
        for field in fields {
            switch field {
            case .name: expected.name = snapshot.name
            case .type: expected.type = snapshot.type
            case .value: expected.value = snapshot.value
            case .autoReplaceSelection: expected.autoReplaceSelection = snapshot.autoReplaceSelection
            case .runInBackground: expected.runInBackground = snapshot.runInBackground
            case .pinned: expected.pinned = snapshot.pinned
            case .next: expected.next = snapshot.next
            }
        }
        return expected
    }

    /// Applies every present field to `snapshot`. Pure: the caller decides
    /// whether the result is worth persisting.
    public func applied(to snapshot: ActionSnapshot) -> ActionSnapshot {
        var result = snapshot
        if let name { result.name = name }
        if let type { result.type = type }
        if let value { result.value = value }
        if let autoReplaceSelection { result.autoReplaceSelection = autoReplaceSelection }
        if let runInBackground { result.runInBackground = runInBackground }
        if let pinned { result.pinned = pinned }
        if let next { result.next = next }
        return result
    }
}

// MARK: - Codable (strict)

extension ActionDraft: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, type, value, autoReplaceSelection, runInBackground, pinned, next
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(known: CodingKeys.self, at: "action")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(CaiActionType.self, forKey: .type)
        self.value = try c.decode(String.self, forKey: .value)
        self.autoReplaceSelection = try c.decodeIfPresent(Bool.self, forKey: .autoReplaceSelection) ?? false
        self.runInBackground = try c.decodeIfPresent(Bool.self, forKey: .runInBackground) ?? false
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.next = try c.decodeIfPresent([ChainStep].self, forKey: .next) ?? []
    }
}

extension ActionPatch: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, type, value, autoReplaceSelection, runInBackground, pinned, next
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(known: CodingKeys.self, at: "changes")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.type = try c.decodeIfPresent(CaiActionType.self, forKey: .type)
        self.value = try c.decodeIfPresent(String.self, forKey: .value)
        self.autoReplaceSelection = try c.decodeIfPresent(Bool.self, forKey: .autoReplaceSelection)
        self.runInBackground = try c.decodeIfPresent(Bool.self, forKey: .runInBackground)
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned)
        self.next = try c.decodeIfPresent([ChainStep].self, forKey: .next)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(autoReplaceSelection, forKey: .autoReplaceSelection)
        try c.encodeIfPresent(runInBackground, forKey: .runInBackground)
        try c.encodeIfPresent(pinned, forKey: .pinned)
        try c.encodeIfPresent(next, forKey: .next)
    }
}

extension PendingChange: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, createdAt, provenance, op, action, targetId, changes, expected
    }

    private enum OperationTag: String, Codable {
        case create, update
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(known: CodingKeys.self, at: "")
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard ActionSchema.supportedVersions.contains(version) else {
            throw ActionRejection.unsupportedSchemaVersion(found: version, supported: ActionSchema.version)
        }
        self.schemaVersion = version
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.provenance = try c.decode(ActionProvenance.self, forKey: .provenance)

        switch try c.decode(OperationTag.self, forKey: .op) {
        case .create:
            // A create carrying update-only keys is a malformed proposal, not
            // a create with extras: reject rather than quietly ignore them.
            try Self.rejectCrossOperationKeys(in: c, forbidden: [.targetId, .changes, .expected], op: "create")
            self.operation = .create(try c.decode(ActionDraft.self, forKey: .action))
        case .update:
            try Self.rejectCrossOperationKeys(in: c, forbidden: [.action], op: "update")
            self.operation = .update(ActionUpdate(
                targetId: try c.decode(UUID.self, forKey: .targetId),
                changes: try c.decode(ActionPatch.self, forKey: .changes),
                expected: try c.decode(ActionPatch.self, forKey: .expected)
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(provenance, forKey: .provenance)
        switch operation {
        case .create(let draft):
            try c.encode(OperationTag.create, forKey: .op)
            try c.encode(draft, forKey: .action)
        case .update(let update):
            try c.encode(OperationTag.update, forKey: .op)
            try c.encode(update.targetId, forKey: .targetId)
            try c.encode(update.changes, forKey: .changes)
            try c.encode(update.expected, forKey: .expected)
        }
    }

    private static func rejectCrossOperationKeys(
        in container: KeyedDecodingContainer<CodingKeys>,
        forbidden: [CodingKeys],
        op: String
    ) throws {
        if let stray = forbidden.first(where: { container.contains($0) }) {
            throw ActionRejection.unknownField("\(op).\(stray.stringValue)")
        }
    }
}
