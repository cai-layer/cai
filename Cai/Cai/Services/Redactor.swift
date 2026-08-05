import Foundation

/// Removes secret values from text that is about to be shown, logged, or kept.
///
/// The last line of defence, not the first. Secrets reach a shell command through
/// the environment and a webhook through a header, so they should never appear in
/// output at all. But `webhookFailed(Int, String)` carries a response body,
/// servers echo request material back, and a command can print its own
/// environment. Anything on that path gets redacted before it becomes an alert,
/// a log line, or a pinned clipboard entry that is written to disk.
enum Redactor {

    static let placeholder = "<redacted>"

    /// Replaces every occurrence of every secret value.
    ///
    /// Longest first, so a secret that contains another (a token and its prefix)
    /// cannot leave a fragment of the longer one behind. Values shorter than 4
    /// characters are skipped: redacting those would blank out ordinary text
    /// wherever they coincide, which hides the error the user needs to read
    /// without protecting anything worth protecting.
    static func redact(_ text: String, using secrets: [SecretValue]) -> String {
        guard !text.isEmpty else { return text }

        let values = secrets
            .map(\.raw)
            .filter { $0.count >= minimumRedactableLength }
            .sorted { $0.count > $1.count }

        var output = text
        for value in values {
            output = output.replacingOccurrences(of: value, with: placeholder)
        }
        return output
    }

    static func redact(_ text: String, using secrets: [String: SecretValue]) -> String {
        redact(text, using: Array(secrets.values))
    }

    /// Below this, a "secret" is too short to distinguish from ordinary text.
    static let minimumRedactableLength = 4
}
