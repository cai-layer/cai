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

    /// `isRevision` skips the queue-full check, and only that check.
    ///
    /// A revision replaces a file that is already in the queue, so it adds no
    /// card. Counting it would deadlock the one case that most needs fixing:
    /// a full queue would lock an agent out of correcting the very proposal
    /// that is filling it. The kill switch and "is Cai running" still apply:
    /// a revision the app will never read is as pointless as a new proposal.
    public static func preflight(
        snapshot: ActionsSnapshot,
        isCaiRunning: Bool,
        pendingCount: Int,
        isRevision: Bool = false
    ) throws {
        try preflightAvailability(snapshot: snapshot, isCaiRunning: isCaiRunning)
        guard isRevision || ActionValidator.hasRoomForAnotherChange(pendingCount: pendingCount) else {
            throw PreflightFailure.queueFull(max: ActionSchema.maxPendingChanges)
        }
    }

    /// The half of preflight that does not depend on what the call turns out
    /// to be. `update_action` runs this before resolving an id, so an agent
    /// working against a switched-off Cai is told that rather than being
    /// handed a resolution error about an id that was never the problem.
    public static func preflightAvailability(
        snapshot: ActionsSnapshot,
        isCaiRunning: Bool
    ) throws {
        guard snapshot.agentAuthoringEnabled else { throw PreflightFailure.authoringDisabled }
        guard isCaiRunning else { throw PreflightFailure.caiNotRunning }
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
    /// never asked for: it is captured from the snapshot in `authoredUpdate`.
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

    /// Resolves an id against the installed snapshot alone. Kept for the
    /// callers that genuinely mean "the stored action": `resolve` below is
    /// what the tools use, because an agent's id can name either half of the
    /// proposal/action lifecycle.
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

    private static func patchProposal(
        target: ActionSnapshot,
        changes: ActionPatch,
        provenance: ActionProvenance,
        id: UUID,
        now: Date
    ) -> PendingChange {
        PendingChange(
            id: id,
            createdAt: now,
            provenance: provenance,
            operation: .update(ActionUpdate(
                targetId: target.id,
                changes: changes,
                expected: changes.capturingCurrentValues(from: target)
            ))
        )
    }
}

// MARK: - Resolving an id across the proposal/action lifecycle

extension AgentAuthoring {

    /// Why an id is being resolved.
    ///
    /// The two differ in one place only: revising another agent's waiting
    /// create is refused, reading it is not. Reading is harmless (the
    /// listing already names every waiting proposal), while writing would
    /// swap a payload under someone else's name on an approval surface.
    /// Another agent's waiting patch is invisible to both: see `resolve`.
    public enum Intent: Equatable, Sendable {
        case read
        case revise
    }

    /// What an agent's id turned out to name.
    public enum Target: Equatable, Sendable {
        /// A stored action. Today's behaviour.
        case installedAction(ActionSnapshot)
        /// A waiting create whose change id is the id the agent passed. For a
        /// create the proposal id already IS the future action id, so this is
        /// the same object the agent is thinking of, one lifecycle stage
        /// earlier.
        case pendingCreate(PendingProposalFile)
        /// A waiting update against the action the agent named.
        case pendingUpdate(PendingProposalFile)
    }

    /// First match wins, in this order:
    ///
    /// 1. a waiting proposal whose own change id is `id` (the id
    ///    `proposalAccepted` hands the agent and `list_actions` lists it under)
    /// 2. a waiting update whose `targetId` is `id`
    /// 3. an installed action whose id is `id`
    /// 4. a quarantined proposal with that id, refused by outcome
    /// 5. nothing, refused
    ///
    /// Rules 1 and 3 cannot both hit: `validateCreate` refuses a proposal
    /// whose id an installed action already answers to.
    ///
    /// Cross-client handling differs by rule, deliberately. At rule 1 there is
    /// nothing else the id can mean, so it is refused. At rule 2 there is:
    /// another client's patch is skipped for both intents, so the caller falls
    /// through to rule 3 and gets (or is told about) its own update card,
    /// which is exactly what happens today. Refusing there instead would let
    /// one agent's waiting card lock every other agent out of an action.
    public static func resolve(
        id: UUID,
        intent: Intent,
        snapshot: ActionsSnapshot,
        pending: [PendingProposalFile],
        statuses: [ProposalStatus],
        client: String?
    ) throws -> Target {
        if let named = pending.first(where: { $0.change.id == id }) {
            // Addressed by its own id, so there is nothing else it can mean:
            // another agent's card is refused here rather than falling through.
            guard intent == .read || isSameClient(named, as: client) else {
                throw ActionRejection.proposalFromAnotherClient(
                    id: id.uuidString,
                    client: named.change.provenance.client.map { ProposalStatus.clamp($0) }
                )
            }
            return named.change.draft != nil ? .pendingCreate(named) : .pendingUpdate(named)
        }

        // Several waiting updates can target one action (two agents, or one
        // agent before this change existed). Newest wins, with the change id
        // breaking a timestamp tie so the answer does not depend on directory
        // order.
        // Filtered by client for reading too, so get_action never describes a
        // waiting patch that update_action would then not revise.
        let updates = pending.filter { $0.change.update?.targetId == id && isSameClient($0, as: client) }
        if let newest = updates.max(by: {
            $0.modifiedAt == $1.modifiedAt
                ? $0.change.id.uuidString < $1.change.id.uuidString
                : $0.modifiedAt < $1.modifiedAt
        }) {
            return .pendingUpdate(newest)
        }

        if let installed = snapshot.actions.first(where: { $0.id == id }) {
            return .installedAction(installed)
        }

        // Only reached for an id that named a proposal rather than an action:
        // a quarantined file is named by change id, and for a create that is
        // the action id the agent kept.
        if let decided = statuses.first(where: {
            $0.id.caseInsensitiveCompare(id.uuidString) == .orderedSame
        }) {
            switch decided.state {
            case .declined:
                throw ActionRejection.proposalDeclined(id: id.uuidString)
            case .refused:
                throw ActionRejection.proposalRefused(id: id.uuidString, reason: decided.reason)
            case .waitingForApproval:
                // Every readable, correctly named pending file was matched by
                // rule 1 above, so this is one `PendingProposals` skipped:
                // unreadable, or named by something other than the id inside
                // it. It is not addressable, so this is "nothing".
                break
            }
        }

        throw ActionRejection.unknownTargetAction(id: id.uuidString)
    }

    /// Two unnamed clients are not the same client: a nil name says nothing
    /// about who wrote the file, so it cannot vouch for a rewrite.
    private static func isSameClient(_ file: PendingProposalFile, as client: String?) -> Bool {
        guard let mine = client, let theirs = file.change.provenance.client else { return false }
        return mine == theirs
    }
}

// MARK: - Authoring an update, whichever half of the lifecycle it lands on

extension AgentAuthoring {

    /// A change ready to be written, and whether it replaces a card the user
    /// already has. The flag decides what the agent is told, so it travels
    /// with the change rather than being re-derived by the caller.
    public struct AuthoredChange: Equatable, Sendable {
        public let change: PendingChange
        public let isRevision: Bool

        public init(change: PendingChange, isRevision: Bool) {
            self.change = change
            self.isRevision = isRevision
        }
    }

    /// Turns a resolved target plus the agent's patch into the file to write.
    ///
    /// **Pending create:** the patch is applied to the draft and written back
    /// under the same change id, so the file and the card are replaced rather
    /// than joined by a second one. No `expected` is involved: nothing is
    /// installed, so there is nothing to clobber.
    ///
    /// **Pending update:** the patch replaces the waiting one wholesale, and
    /// `expected` is captured fresh from the live action. It does not overlay
    /// the earlier patch field by field: that would give `update_action` a
    /// second meaning (a delta against the agent's own previous delta) for one
    /// case, where every other call means "this is my patch against the
    /// action". `Tools.updateAction` says so, so an agent sends the whole
    /// change it still wants.
    ///
    /// **Installed action:** today's behaviour, a new card.
    public static func authoredUpdate(
        target: Target,
        input: UpdateInput,
        snapshot: ActionsSnapshot,
        provenance: ActionProvenance,
        newChangeId: UUID,
        now: Date
    ) throws -> AuthoredChange {
        guard !input.changes.isEmpty else { throw ActionRejection.emptyPatch }

        switch target {
        case .installedAction(let action):
            return AuthoredChange(
                change: patchProposal(
                    target: action, changes: input.changes,
                    provenance: provenance, id: newChangeId, now: now
                ),
                isRevision: false
            )

        case .pendingCreate(let file):
            guard let draft = file.change.draft else {
                throw ActionRejection.unknownTargetAction(id: input.id.uuidString)
            }
            let merged = input.changes.applied(to: draft.snapshot(id: file.change.id))
            return AuthoredChange(
                change: PendingChange(
                    id: file.change.id,
                    createdAt: now,
                    provenance: restamped(file.change.provenance, now: now),
                    operation: .create(ActionDraft(snapshot: merged))
                ),
                isRevision: true
            )

        case .pendingUpdate(let file):
            // The action the waiting patch targets must still exist: the user
            // can delete it while the card waits, and a patch against nothing
            // is the same refusal `validateUpdate` gives at approval time.
            // Resolved from the file, not from `input.id`: the agent may have
            // addressed this card by its proposal id rather than the action's.
            guard let targetId = file.change.update?.targetId else {
                throw ActionRejection.unknownTargetAction(id: input.id.uuidString)
            }
            let action = try action(id: targetId, snapshot: snapshot)
            return AuthoredChange(
                change: patchProposal(
                    target: action, changes: input.changes,
                    provenance: restamped(file.change.provenance, now: now),
                    id: file.change.id, now: now
                ),
                isRevision: true
            )
        }
    }

    /// A revision keeps the author the card already names and moves only the
    /// clock: the card should say when the bytes the user is reading were
    /// written, not when the agent first raised the need.
    private static func restamped(_ provenance: ActionProvenance, now: Date) -> ActionProvenance {
        ActionProvenance(
            source: provenance.source,
            client: provenance.client,
            model: provenance.model,
            authoredAt: now
        )
    }
}
