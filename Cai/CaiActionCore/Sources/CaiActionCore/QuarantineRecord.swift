import Foundation

/// Written beside a quarantined proposal, as `<id>.rejection.json`.
///
/// The original file may not even be valid JSON, so the reason cannot live
/// inside it. The app writes this; the helper reads it to answer "what
/// happened to my proposal" in `list_actions`. Shared here so the two can
/// never disagree about the format.
public struct QuarantineRecord: Codable, Equatable, Sendable {

    /// Who said no. The agent needs these apart: a refusal is something it can
    /// fix and retry, a decline is the user's answer and retrying it is
    /// pestering them with the same proposal.
    public enum Outcome: String, Codable, Sendable {
        /// Cai would not accept the proposal.
        case refused
        /// The user read it and said no.
        case declined
    }

    public let schemaVersion: Int
    public let rejectedAt: Date
    public let reason: String
    public let outcome: Outcome
    /// Name of the proposed action, so the agent can tell which of its
    /// proposals this verdict is about. `nil` when the original file never
    /// decoded far enough to have one.
    public let actionName: String?
    /// The connecting client's name from the proposal's provenance, so with
    /// two agents connected each can tell whose proposal was decided.
    public let client: String?

    public init(
        schemaVersion: Int = ActionSchema.version,
        rejectedAt: Date,
        reason: String,
        outcome: Outcome = .refused,
        actionName: String? = nil,
        client: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.rejectedAt = rejectedAt
        self.reason = reason
        self.outcome = outcome
        self.actionName = actionName
        self.client = client
    }

    /// `outcome` defaults rather than throwing, so a sidecar written by an
    /// older Cai still decodes and the agent keeps getting its reason.
    /// `actionName` and `client` likewise: absent in older sidecars.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.rejectedAt = try container.decode(Date.self, forKey: .rejectedAt)
        self.reason = try container.decode(String.self, forKey: .reason)
        self.outcome = try container.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .refused
        self.actionName = try container.decodeIfPresent(String.self, forKey: .actionName)
        self.client = try container.decodeIfPresent(String.self, forKey: .client)
    }
}
