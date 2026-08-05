import Foundation

/// Named secrets as they appear inside an action: `{{NOTION_API_TOKEN}}`.
///
/// The action stores the reference; the value lives in the Keychain and is
/// resolved at execution time. That is what lets an agent author an action that
/// uses a token, and a user export or share one, without either seeing it.
///
/// **The name shape is what marks a placeholder as a secret reference.** Every
/// other variable in Cai is lowercase (`result`, and the MCP form keys), so
/// upper-case placeholders are unambiguous. Note what this does *not* mean:
/// nothing is protected because of how it is named. A mistyped reference
/// resolves to no secret and is refused, never stored or sent. That is the
/// difference from Keyboard Maestro, where a variable is protected only if its
/// name contains "password" and a typo silently writes the value to disk.
public enum SecretReference {

    /// Keychain account prefix. Sits under the same service as the model API
    /// keys, so `cai_secret_` is what separates the two families.
    public static let accountPrefix = "cai_secret_"

    /// Environment variable prefix. A shell template's `{{NOTION_API_TOKEN}}`
    /// renders as `"$CAI_SECRET_NOTION_API_TOKEN"` and the value arrives through
    /// the process environment, so it never enters the command line.
    public static let environmentPrefix = "CAI_SECRET_"

    public static let maxNameLength = 64

    // MARK: - Names

    /// Upper-case, digits and underscores, starting with a letter, 2 to 64
    /// characters.
    ///
    /// Hand-rolled rather than a regex so the rule is readable and cannot
    /// surprise anyone with backtracking behaviour.
    public static func isValidName(_ name: String) -> Bool {
        guard name.count >= 2, name.count <= maxNameLength else { return false }
        guard let first = name.first, first.isASCII, first.isUppercase else { return false }
        return name.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isUppercase || character.isNumber || character == "_"
        }
    }

    /// Why a name was rejected, phrased for the person typing it.
    public static func nameRejection(_ name: String) -> String? {
        if name.isEmpty { return "Give the secret a name." }
        if name.count < 2 { return "Use at least two characters." }
        if name.count > maxNameLength { return "Keep the name under \(maxNameLength) characters." }
        if let first = name.first, !(first.isASCII && first.isUppercase) {
            return "Start with an upper-case letter, like NOTION_API_TOKEN."
        }
        if !isValidName(name) {
            return "Use upper-case letters, numbers and underscores only."
        }
        return nil
    }

    public static func accountName(for name: String) -> String {
        accountPrefix + name
    }

    /// The secret name inside a Keychain account, or nil for accounts that
    /// belong to something else (the model API keys share the service).
    public static func name(fromAccount account: String) -> String? {
        guard account.hasPrefix(accountPrefix) else { return nil }
        let name = String(account.dropFirst(accountPrefix.count))
        return isValidName(name) ? name : nil
    }

    public static func environmentVariable(for name: String) -> String {
        environmentPrefix + name
    }

    // MARK: - Finding references in a template

    /// Every secret name a template refers to.
    ///
    /// Deliberately a separate, stricter scanner than `TemplateEngine`'s parser:
    /// this runs in the shared package so the validator can flag a proposed
    /// action that reaches for a token, and it must not depend on the app. The
    /// two agreeing matters, so `SecretReferenceAgreementTests` cross-checks
    /// them against a corpus rather than trusting that they drift together.
    ///
    /// Filters are ignored here: `{{TOKEN|json}}` refers to `TOKEN`.
    public static func names(in template: String) -> Set<String> {
        var found: Set<String> = []
        var remainder = Substring(template)

        while let open = remainder.range(of: "{{") {
            remainder = remainder[open.upperBound...]
            guard let close = remainder.range(of: "}}") else { break }
            let body = remainder[..<close.lowerBound]
            remainder = remainder[close.upperBound...]

            // The variable is everything before the first filter pipe.
            let variable = body.prefix { $0 != "|" }.trimmingCharacters(in: .whitespaces)
            if isValidName(variable) {
                found.insert(variable)
            }
        }
        return found
    }

    /// Whether a template refers to any secret at all. The question the
    /// approval sheet asks.
    public static func referencesAnySecret(_ template: String) -> Bool {
        !names(in: template).isEmpty
    }
}
