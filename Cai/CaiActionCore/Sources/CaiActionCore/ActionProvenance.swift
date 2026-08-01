import Foundation

/// Who authored a change, and how.
///
/// Provenance is carried on the pending change AND copied onto the approved
/// `CaiShortcut`, so weeks later the shortcuts list can still answer "where
/// did this come from" with a badge. The source is an enum rather than a bool
/// so the in-app authoring front-end can reuse this whole pipeline by writing
/// `{source: "in-app", model: "..."}` without a schema change.
public struct ActionProvenance: Codable, Equatable, Sendable {

    public enum Source: String, Codable, Equatable, Sendable {
        /// Authored by an external agent over the stdio MCP helper.
        case mcp
        /// Authored inside Cai by the local model (reserved; not written yet).
        case inApp = "in-app"
    }

    public let source: Source
    /// `clientInfo.name` from the MCP handshake, e.g. "Claude Code". Optional
    /// because the handshake field is optional in the protocol.
    public let client: String?
    /// Model identifier, for the in-app source. Never populated by the helper:
    /// the helper cannot know which model its client is running.
    public let model: String?
    public let authoredAt: Date

    public init(source: Source, client: String? = nil, model: String? = nil, authoredAt: Date) {
        self.source = source
        self.client = client
        self.model = model
        self.authoredAt = authoredAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, client, model, authoredAt
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(known: CodingKeys.self, at: "provenance")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try c.decode(Source.self, forKey: .source)
        self.client = try c.decodeIfPresent(String.self, forKey: .client)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.authoredAt = try c.decode(Date.self, forKey: .authoredAt)
    }
}
