import Foundation

/// Written beside a quarantined proposal, as `<id>.rejection.json`.
///
/// The original file may not even be valid JSON, so the reason cannot live
/// inside it. The app writes this; the helper reads it to answer "what
/// happened to my proposal" in `list_actions`. Shared here so the two can
/// never disagree about the format.
public struct QuarantineRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let rejectedAt: Date
    public let reason: String

    public init(schemaVersion: Int = ActionSchema.version, rejectedAt: Date, reason: String) {
        self.schemaVersion = schemaVersion
        self.rejectedAt = rejectedAt
        self.reason = reason
    }
}
