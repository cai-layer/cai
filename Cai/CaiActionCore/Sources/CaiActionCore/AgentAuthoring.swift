import Foundation

/// Everything that turns an agent's tool call into a proposal, minus the
/// transport.
///
/// This lives in the package rather than in the `cai-mcp` executable for one
/// reason: a command-line target has nowhere to hang unit tests, and this is
/// the code that decides what an agent is allowed to say and what the user
/// will be shown. The helper is left holding the MCP plumbing, which is the
/// part a test could not meaningfully cover anyway.
public enum AgentAuthoring {

    // MARK: - Preflight

    /// Conditions that make writing a proposal pointless, separated from the
    /// question of whether the proposal itself is any good.
    ///
    /// Each reason is phrased for an agent to act on: the difference between
    /// "Cai has never run" and "the user switched this off" is the difference
    /// between retrying and telling the user something.
    public enum PreflightFailure: Error, Equatable {
        case caiNotRunning
        case authoringDisabled
        case queueFull(max: Int)

        public var reason: String {
            switch self {
            case .caiNotRunning:
                return "Cai is not running, so it cannot show this for approval. Ask the user to open Cai and try again."
            case .authoringDisabled:
                return "The user has turned off \"Allow agents to propose actions\" in Cai's settings. Ask them to turn it back on if they want this."
            case .queueFull(let max):
                return ActionRejection.queueFull(max: max).reason
            }
        }
    }

    public static func preflight(
        snapshot: ActionsSnapshot,
        isCaiRunning: Bool,
        pendingCount: Int
    ) throws {
        guard snapshot.agentAuthoringEnabled else { throw PreflightFailure.authoringDisabled }
        guard isCaiRunning else { throw PreflightFailure.caiNotRunning }
        guard ActionValidator.hasRoomForAnotherChange(pendingCount: pendingCount) else {
            throw PreflightFailure.queueFull(max: ActionSchema.maxPendingChanges)
        }
    }

    // MARK: - Decoding tool arguments

    /// Arguments arrive as JSON. Decoding them with the same strict types the
    /// wire format uses means a misspelled argument is refused here, with the
    /// same wording, rather than silently dropped into a proposal that differs
    /// from what the agent described.
    public static func decodeCreate(arguments: Data) throws -> ActionDraft {
        try decode(ActionDraft.self, from: arguments)
    }

    /// `{id, changes}`, exactly as `update_action` documents. `expected` is
    /// never asked for: it is captured from the snapshot in `updateProposal`.
    public struct UpdateInput: Equatable, Decodable {
        public let id: UUID
        public let changes: ActionPatch

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, changes
        }

        public init(id: UUID, changes: ActionPatch) {
            self.id = id
            self.changes = changes
        }

        public init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(known: CodingKeys.self, at: "")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(UUID.self, forKey: .id)
            self.changes = try container.decode(ActionPatch.self, forKey: .changes)
        }
    }

    public static func decodeUpdate(arguments: Data) throws -> UpdateInput {
        try decode(UpdateInput.self, from: arguments)
    }

    /// `{id}`, for `get_action`.
    public struct ActionRef: Equatable, Decodable {
        public let id: UUID

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id
        }

        public init(id: UUID) {
            self.id = id
        }

        public init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(known: CodingKeys.self, at: "")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(UUID.self, forKey: .id)
        }
    }

    public static func decodeActionRef(arguments: Data) throws -> ActionRef {
        try decode(ActionRef.self, from: arguments)
    }

    /// Resolves an id against the snapshot, with the same rejection an update
    /// gives, so an agent gets one wording for "no such action".
    public static func action(id: UUID, snapshot: ActionsSnapshot) throws -> ActionSnapshot {
        guard let target = snapshot.actions.first(where: { $0.id == id }) else {
            throw ActionRejection.unknownTargetAction(id: id.uuidString)
        }
        return target
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try ActionCoding.decoder.decode(type, from: data)
        } catch let rejection as ActionRejection {
            throw rejection
        } catch let decoding as DecodingError {
            throw ActionRejection.malformedJSON(describe(decoding))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            return "missing required argument '\(key.stringValue)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "wrong type for '\(path)'"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return "the arguments could not be read"
        }
    }

    // MARK: - Building proposals

    public static func createProposal(
        draft: ActionDraft,
        provenance: ActionProvenance,
        id: UUID,
        now: Date
    ) -> PendingChange {
        PendingChange(id: id, createdAt: now, provenance: provenance, operation: .create(draft))
    }

    /// Builds an update, capturing what the action looks like right now so the
    /// app can refuse the patch if the user changes it in the meantime.
    public static func updateProposal(
        input: UpdateInput,
        snapshot: ActionsSnapshot,
        provenance: ActionProvenance,
        id: UUID,
        now: Date
    ) throws -> PendingChange {
        guard let target = snapshot.actions.first(where: { $0.id == input.id }) else {
            throw ActionRejection.unknownTargetAction(id: input.id.uuidString)
        }
        return PendingChange(
            id: id,
            createdAt: now,
            provenance: provenance,
            operation: .update(ActionUpdate(
                targetId: target.id,
                changes: input.changes,
                expected: input.changes.capturingCurrentValues(from: target)
            ))
        )
    }
}
