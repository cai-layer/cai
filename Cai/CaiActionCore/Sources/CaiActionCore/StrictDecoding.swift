import Foundation

/// A `CodingKey` that accepts anything, used to enumerate the keys actually
/// present in a JSON object.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Decoder {

    /// Throws `ActionRejection.unknownField` when the object carries a key
    /// outside the declared set.
    ///
    /// Swift's Codable ignores unknown keys by default, which is exactly wrong
    /// here: a typo'd or invented field would be silently dropped and the user
    /// would approve an action that isn't the one the agent described. Every
    /// DTO in this package rejects loudly instead, and the rejection reason
    /// names the field so the agent can fix it in one retry.
    func rejectUnknownKeys<K: CodingKey & CaseIterable>(known: K.Type, at context: String) throws {
        let declared = Set(K.allCases.map(\.stringValue))
        let present = try container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
        // Sorted so the reported field is stable when a payload carries more
        // than one unknown key (deterministic messages keep tests honest).
        if let unknown = present.filter({ !declared.contains($0) }).sorted().first {
            throw ActionRejection.unknownField(context.isEmpty ? unknown : "\(context).\(unknown)")
        }
    }
}

/// Shared JSON coders for everything written to or read from
/// `~/Library/Application Support/Cai/`.
///
/// ISO-8601 dates keep the pending files, the audit log and the snapshot
/// human-readable, which matters because those files are the debugging
/// surface for the whole handoff: the user (or a bug report) can read them
/// without Cai running.
public enum ActionCoding {

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
