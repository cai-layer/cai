import Foundation

/// Named secrets as they appear inside an action: `{{secrets.NOTION_API_TOKEN}}`.
///
/// The action stores the reference; the value lives in the Keychain and is
/// resolved at execution time. That is what lets an agent author an action that
/// uses a token, and a user export or share one, without either seeing it.
///
/// **The `secrets.` namespace is what marks a placeholder as a secret
/// reference.** Nothing else can collide with it: ordinary variables (`result`,
/// setup-field keys, MCP form keys) have no such prefix, whatever their casing,
/// so no existing template changes meaning. The spelling is GitHub Actions'
/// (`secrets.NAME`), which is the one most users already know. Note what this
/// does *not* mean: nothing is protected because of how it is named. A mistyped
/// reference resolves to no secret and is refused, never stored or sent. That is
/// the difference from Keyboard Maestro, where a variable is protected only if
/// its name contains "password" and a typo silently writes the value to disk.
public enum SecretReference {

    /// Placeholder namespace. `{{secrets.NOTION_API_TOKEN}}` refers to the
    /// secret named `NOTION_API_TOKEN`.
    public static let referencePrefix = "secrets."

    /// Keychain account prefix. Sits under the same service as the model API
    /// keys, so `cai_secret_` is what separates the two families.
    public static let accountPrefix = "cai_secret_"

    /// Environment variable prefix. A shell template's
    /// `{{secrets.NOTION_API_TOKEN}}` renders as
    /// `"$CAI_SECRET_NOTION_API_TOKEN"` and the value arrives through the
    /// process environment, so it never enters the command line. The name is the
    /// env-var name on purpose: the planned fallback resolves a secret Cai does
    /// not hold from the user's own shell environment, same name, no second copy.
    public static let environmentPrefix = "CAI_SECRET_"

    public static let maxNameLength = 64

    // MARK: - Names

    /// Upper-case, digits and underscores, starting with a letter, 2 to 64
    /// characters. Env-var shape, because the name must survive as one.
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

    /// The secret name inside a placeholder variable, or nil when the variable
    /// is not in the `secrets.` namespace. `"secrets.NOTION_API_TOKEN"` →
    /// `"NOTION_API_TOKEN"`; `"result"` → nil; `"secrets.bad-name"` → nil
    /// (the caller decides whether that is an error, and for the engine it is:
    /// reaching into the namespace with a broken name must be loud).
    public static func name(fromReference variable: String) -> String? {
        guard variable.hasPrefix(referencePrefix) else { return nil }
        let name = String(variable.dropFirst(referencePrefix.count))
        return isValidName(name) ? name : nil
    }

    /// Whether a placeholder variable claims the `secrets.` namespace at all,
    /// valid name or not. What separates "not a secret" from "a secret
    /// reference written wrong".
    public static func claimsNamespace(_ variable: String) -> Bool {
        variable.hasPrefix(referencePrefix)
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

    /// Every secret name a template appears to refer to.
    ///
    /// This is the shared package's scanner, for the validator's question "does
    /// this proposed action touch a secret?", where it must not depend on the
    /// app. It is deliberately simpler than `TemplateEngine`'s quote-aware
    /// parser, and the contract is **it may over-report but must never
    /// under-report** relative to what the engine resolves: a false positive
    /// makes a proposal look slightly scarier than it is; a false negative would
    /// hide a credential from the approval sheet. The agreement test in
    /// `SecretReferenceTests` pins that direction on a corpus, including the
    /// quoted-`}}` templates where the two genuinely disagree. Execution never
    /// trusts this scanner: `SecretStore.prepareForShell` takes its names from
    /// the engine's own parse.
    ///
    /// Filters are ignored here: `{{secrets.TOKEN|json}}` refers to `TOKEN`.
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
            if let name = name(fromReference: variable) {
                found.insert(name)
            }
        }
        return found
    }

    /// Whether a template refers to any secret at all. The question the
    /// approval sheet asks (wired in the secrets-ui PR).
    public static func referencesAnySecret(_ template: String) -> Bool {
        !names(in: template).isEmpty
    }
}
