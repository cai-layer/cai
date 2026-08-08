import CaiActionCore
import Foundation

// MARK: - Template Engine

/// Resolves Cai's template syntax (`{{var|filter|filter:"arg"}}`) into a final string.
/// Used by every surface that substitutes user-authored templates: shell shortcuts,
/// shell/webhook/deeplink/AppleScript destinations, and (with `Context.raw`) MCP form fields.
///
/// **Design:** pure function (no I/O, no state in the engine itself); filters can be
/// async (e.g. `|llm` calls `LLMService`). Filter resolution is by name lookup, not
/// switch — adding a new filter is a one-liner in the registry.
///
/// **Spec:** see `_docs/planning/active/SHELL-TODOS.md` — "Revised plan" + "Updates 2026-05-03"
/// for the locked API and design decisions.
struct TemplateEngine {

    // MARK: - Public Types

    /// Surface-specific context. Selects the default filter applied when a template
    /// uses bare `{{result}}` with no explicit filter chain.
    enum Context {
        /// Shell command. Default filter: `|shell` (single-quote wrap + escape).
        /// Used by both shortcut shell and shell destinations after unification.
        case shell
        /// URL or deeplink. Default filter: `|url_encode`.
        case url
        /// JSON body (e.g. webhook payload). Default filter: `|json`.
        case json
        /// No default filter. Used for MCP forms, prompt input, and AppleScript
        /// destinations (call site does its own escaping for AppleScript).
        case raw
    }

    /// Permission for a call site to resolve `{{secrets.NAME}}` references.
    ///
    /// **This is a property of the destination, not of `Context`.** `Context`
    /// selects an escaping filter, and two very different sinks share
    /// `Context.raw`: webhook headers, where a token is the whole point, and LLM
    /// prompts, whose rendered output goes verbatim to a model. So the call site
    /// has to say, and the safe answer is the default: passing `nil` refuses.
    ///
    /// The only grant that exists is the shell one: the rendered command gets
    /// `"$CAI_SECRET_NAME"` and the value travels in the process environment, so
    /// it never appears in the rendered string that reaches the result UI,
    /// history, or process listings visible to other users. (A same-uid process
    /// can still read a child's environment; env narrows exposure, it does not
    /// erase it.) Webhook substitution is a future grant, deliberately not
    /// shipped unused so it can land fail-closed with its call site.
    ///
    /// Refusal throws rather than resolving to empty. An action that appears to
    /// work while sending no credential is the failure people ship.
    struct SecretAccess {
        /// The resolved values, for reference lookup and post-run redaction.
        let values: [String: SecretValue]
    }

    /// Errors thrown during template parsing or filter execution.
    enum FilterError: Error, LocalizedError {
        case parseError(String)
        case unknownFilter(String)
        case badArgument(String, filter: String)
        case llmFailed(String)
        case busy
        /// The template reaches for a secret in a place secrets may not go.
        case secretNotAllowed(name: String)
        /// The template reaches for a secret that does not exist.
        case unknownSecret(name: String)
        /// A filter that would move a secret somewhere it must not go.
        case secretThroughFilter(name: String, filter: String)
        /// The Keychain refused the lookup (locked, denied). Distinct from
        /// `unknownSecret`: telling the user to re-add a secret that exists
        /// invites them to overwrite it.
        case keychainUnavailable(status: OSStatus)
        /// The reference sits inside single quotes, where the shell would send
        /// the literal `$CAI_SECRET_*` text as the credential.
        case secretInSingleQuotes(name: String)

        var errorDescription: String? {
            switch self {
            case .parseError(let msg):
                return "Template parse error: \(msg)"
            case .unknownFilter(let name):
                return "Unknown filter: |\(name)"
            case .badArgument(let msg, let filter):
                return "Bad argument for |\(filter): \(msg)"
            case .llmFailed(let detail):
                return "LLM filter failed: \(detail)"
            case .busy:
                return "Cai is busy. Try again in a moment."
            case .secretNotAllowed(let name):
                return "{{secrets.\(name)}} can't be used here. Secrets work only in shell commands for now."
            case .unknownSecret(let name):
                return "No secret named \(name) is stored on this Mac. Add it in Settings → Secrets."
            case .secretThroughFilter(let name, let filter):
                return "{{secrets.\(name)}} can't go through |\(filter). Filters could move the value somewhere Cai can't protect."
            case .keychainUnavailable(let status):
                return "Cai couldn't read your secrets from the Keychain (error \(status)). Unlock the login keychain and try again."
            case .secretInSingleQuotes(let name):
                return "{{secrets.\(name)}} is inside single quotes, so the shell would send the literal text instead of the secret. Put it in double quotes."
            }
        }
    }

    // MARK: - Public API

    /// Renders a template by substituting variables and applying the filter chain.
    /// Filters chain left-to-right: `{{result|trim|llm:"summarize"|json}}`.
    ///
    /// - Parameters:
    ///   - template: the template string (may contain `{{var|filters}}` placeholders).
    ///   - vars: variable values keyed by name (e.g. `["result": clipboardText]`).
    ///     Standard variable in v1 is `{{result}}`; call sites may pass arbitrary
    ///     additional keys (MCP forms pass `{{title}}`, `{{repo_owner}}`, etc.).
    ///   - context: controls the default filter applied when no `|filter` is
    ///     present in a `{{...}}` placeholder.
    ///   - sourceBundleId: optional bundle ID of the app the user copied from.
    ///     Forwarded to `|llm` filter so per-app Context Snippets are injected.
    /// - Returns: the rendered string with all placeholders resolved.
    /// - Throws: `FilterError.parseError` on malformed templates,
    ///   `FilterError.unknownFilter` on unrecognized filter names,
    ///   `FilterError.llmFailed` if an `|llm` filter call fails,
    ///   `FilterError.busy` if MLX is mid-generation when an `|llm` call dispatches.
    static func render(
        _ template: String,
        vars: [String: String],
        context: Context,
        sourceBundleId: String? = nil,
        secrets: SecretAccess? = nil
    ) async throws -> String {
        let segments = try parse(template)
        var output = ""
        for segment in segments {
            switch segment {
            case .literal(let text):
                output += text
            case .placeholder(let varName, let filters)
                where SecretReference.claimsNamespace(varName):
                // `secrets.*` placeholders are secret references, and every sink
                // that has not opted in refuses them. See `SecretAccess`. A
                // broken name inside the namespace is loud, unlike ordinary
                // unknown variables: nobody decorates a template with
                // `{{secrets.…}}` by accident.
                guard let name = SecretReference.name(fromReference: varName) else {
                    throw FilterError.parseError(
                        "{{\(varName)}} is not a valid secret reference. Names look like secrets.NOTION_API_TOKEN."
                    )
                }
                let reference = try resolveSecret(
                    named: name,
                    filterNames: filters.map(\.name),
                    access: secrets
                )
                // zsh expands nothing inside single quotes; the literal
                // reference would be sent as the credential. Refuse rather
                // than misfire silently.
                if context == .shell, endsInsideSingleQuote(output) {
                    throw FilterError.secretInSingleQuotes(name: name)
                }
                output += reference
            case .placeholder(let varName, let filters):
                // Unknown variable → empty string. We don't throw here because copying
                // templates between contexts (e.g. {{title}} in a shell shortcut) is
                // common and shouldn't kill the action.
                let initial = vars[varName] ?? ""
                var chain = filters.isEmpty ? defaultChain(for: context) : filters
                // Safe-by-default: when the user wrote an explicit filter chain, ensure
                // it ends in the context's safety filter (so e.g. `|llm:"..."` in a
                // shell template gets `|shell` appended automatically). Skip if the
                // user explicitly opted out with `|raw` or already used the matching
                // filter. Without this, every chained-filter user has to remember to
                // append `|shell` themselves — confirmed footgun in real use.
                if !filters.isEmpty,
                   let safety = safetyFilter(for: context),
                   let lastName = chain.last?.name,
                   lastName != "raw" && lastName != safety {
                    chain.append(FilterCall(name: safety, args: []))
                }
                var value = initial
                for call in chain {
                    guard let filter = filterRegistry[call.name] else {
                        throw FilterError.unknownFilter(call.name)
                    }
                    value = try await filter.apply(
                        value,
                        args: call.args,
                        sourceBundleId: sourceBundleId
                    )
                }
                output += value
            }
        }
        return output
    }

    // MARK: - Secrets

    /// Filters that are not refused hard on a secret reference. `|raw` is
    /// accepted as a no-op, since an environment reference is never escaped,
    /// which is exactly what `|raw` asks for. `|json` and `|url_encode` are
    /// refused gently (they cannot apply to a value that never enters the
    /// output). Anything else — above all `|llm` — is refused hard: it would
    /// move the value somewhere it must not go, which is the entire thing this
    /// design prevents.
    static let filtersAllowedOnSecrets: Set<String> = ["json", "url_encode", "raw"]

    /// Resolves one `{{secrets.NAME}}` placeholder to its environment
    /// reference, or throws.
    ///
    /// Takes its values as an argument rather than reading the Keychain, so the
    /// whole policy is covered by `SecretPolicyTests` without a live store. The
    /// value itself never enters the rendered command: the returned reference is
    /// double-quoted so a secret containing spaces stays one word, and the shell
    /// expands it after we are done.
    static func resolveSecret(
        named name: String,
        filterNames: [String],
        access: SecretAccess?
    ) throws -> String {
        guard let access else {
            throw FilterError.secretNotAllowed(name: name)
        }
        guard access.values[name] != nil else {
            throw FilterError.unknownSecret(name: name)
        }

        if let offending = filterNames.first(where: { !filtersAllowedOnSecrets.contains($0) }) {
            throw FilterError.secretThroughFilter(name: name, filter: offending)
        }
        if let inapplicable = filterNames.first(where: { $0 != "raw" }) {
            throw FilterError.badArgument(
                "a secret in a shell command is passed through the environment, so escaping filters do not apply to it",
                filter: inapplicable
            )
        }

        return "\"$\(SecretReference.environmentVariable(for: name))\""
    }

    /// The secret names a template resolves, per the engine's own parser.
    ///
    /// This is what `SecretStore.prepareForShell` uses, so execution can never
    /// disagree with rendering about which secrets a command needs. (The
    /// quote-blind scanner in `SecretReference` may over-report on templates
    /// with `}}` inside quoted filter args; it serves only the validator's
    /// advisory question.) Malformed templates return empty and leave the parse
    /// error to `render`, where it is thrown with context.
    static func secretNames(in template: String) -> Set<String> {
        guard let segments = try? parse(template) else { return [] }
        var found: Set<String> = []
        for case .placeholder(let varName, _) in segments {
            if let name = SecretReference.name(fromReference: varName) {
                found.insert(name)
            }
        }
        return found
    }

    /// Whether a rendered shell-command prefix ends inside an unclosed single
    /// quote. zsh expands nothing there, so an environment reference emitted at
    /// that position would send literal text as the credential. Backslash
    /// escapes the next character except inside single quotes, which is zsh's
    /// rule.
    static func endsInsideSingleQuote(_ prefix: String) -> Bool {
        var quote: Character? = nil
        var escaped = false
        for character in prefix {
            if escaped {
                escaped = false
                continue
            }
            switch quote {
            case "'":
                if character == "'" { quote = nil }
            case "\"":
                if character == "\\" { escaped = true } else if character == "\"" { quote = nil }
            default:
                if character == "\\" { escaped = true } else if character == "'" || character == "\"" { quote = character }
            }
        }
        return quote == "'"
    }

    // MARK: - Default Filter per Context

    /// The context's "safety filter" — the escape that keeps output safe for that
    /// surface. Used in two places: (a) as the chain when no filters are written,
    /// and (b) auto-appended at the end of any explicit chain unless the user
    /// opted out with `|raw` or already used the matching filter. `nil` for `.raw`.
    private static func safetyFilter(for context: Context) -> String? {
        switch context {
        case .shell: return "shell"
        case .url:   return "url_encode"
        case .json:  return "json"
        case .raw:   return nil
        }
    }

    /// Returns the default filter chain for a context. Applied when a placeholder
    /// has no explicit `|filter` segments. Wraps `safetyFilter(for:)` in an array.
    private static func defaultChain(for context: Context) -> [FilterCall] {
        if let safety = safetyFilter(for: context) {
            return [FilterCall(name: safety, args: [])]
        }
        return []
    }

    // MARK: - Filter Registry

    /// Filter lookup table. Adding a new filter is a one-liner here — the engine
    /// itself never branches on filter name.
    private static let filterRegistry: [String: Filter] = [
        "raw":        RawFilter(),
        "shell":      ShellFilter(),
        "json":       JsonFilter(),
        "url_encode": UrlEncodeFilter(),
        "llm":        LLMFilter(),
    ]

    // MARK: - v1 → v2 Migration (shortcut shell templates only)

    /// Rewrites the v1 single-/double-quote-wrapped pattern in a shortcut shell
    /// template to v2 filter syntax.
    ///
    /// **Single mechanical pattern** (the only safely-migratable case):
    /// - `'{{result}}'` → `{{result|shell}}` (straight single quotes)
    /// - `"{{result}}"` → `{{result|shell}}` (straight double quotes)
    /// - `\u{2018}{{result}}\u{2019}` → `{{result|shell}}` (typographic single)
    /// - `\u{201C}{{result}}\u{201D}` → `{{result|shell}}` (typographic double)
    ///
    /// Curly/typographic quotes are included because macOS's smart-quote
    /// autocorrect silently substitutes them in NSTextView/TextField — legacy
    /// templates persisted before the save-time `normalizingSmartQuotes()` fix
    /// can have them on disk. Catching them here lets the launch-time
    /// migration clean those up too.
    ///
    /// All other content passes through unchanged. Bare `{{result}}` is *not*
    /// rewritten — it's behavior-preserving under `Context.shell`'s default
    /// `|shell` filter at render time.
    ///
    /// **Idempotent.** After rewrite the pattern is gone, so running on already-
    /// migrated text is a no-op. Templates already authored in v2 syntax (e.g.
    /// `{{result|raw}}`) are also unaffected — none of the literal patterns
    /// appear.
    ///
    /// Called once per user from `CaiSettings.init()` behind a one-shot flag,
    /// and per-save in the shortcut editor as a safety net for new shortcuts.
    /// See `_docs/planning/active/SHELL-TODOS.md` "Updates 2026-05-03" for spec.
    static func migrateShellTemplate(_ template: String) -> String {
        return template
            .replacingOccurrences(of: "'{{result}}'", with: "{{result|shell}}")
            .replacingOccurrences(of: "\"{{result}}\"", with: "{{result|shell}}")
            .replacingOccurrences(of: "\u{2018}{{result}}\u{2019}", with: "{{result|shell}}")
            .replacingOccurrences(of: "\u{201C}{{result}}\u{201D}", with: "{{result|shell}}")
    }
}

// MARK: - Parsing

extension TemplateEngine {

    /// A parsed segment of the template — either literal text or a `{{...}}` placeholder.
    fileprivate enum Segment: Equatable {
        case literal(String)
        case placeholder(variable: String, filters: [FilterCall])
    }

    /// A single filter invocation parsed from the template.
    fileprivate struct FilterCall: Equatable {
        let name: String
        let args: [String]
    }

    /// Parses a template string into segments. Hand-rolled scanner — regex bites on
    /// filter args containing `}`, `|`, or unbalanced quotes.
    ///
    /// The scanner has three implicit states:
    /// - `LITERAL` — outside `{{...}}`
    /// - `INSIDE_BRACES` — between `{{` and `}}` (handled by `findPlaceholderEnd`)
    /// - `INSIDE_QUOTED_ARG` — inside `"..."` or `'...'` within a placeholder
    ///   (handled by quote-tracking in `findPlaceholderEnd` and `splitTopLevel`)
    fileprivate static func parse(_ template: String) throws -> [Segment] {
        var segments: [Segment] = []
        var literal = ""
        var i = template.startIndex

        while i < template.endIndex {
            let next = template.index(after: i)
            // Look for `{{` start
            if template[i] == "{" && next < template.endIndex && template[next] == "{" {
                if !literal.isEmpty {
                    segments.append(.literal(literal))
                    literal = ""
                }
                let contentStart = template.index(i, offsetBy: 2)
                guard let contentEnd = findPlaceholderEnd(in: template, from: contentStart) else {
                    let offset = template.distance(from: template.startIndex, to: i)
                    throw FilterError.parseError("unclosed `{{` at offset \(offset)")
                }
                let inside = String(template[contentStart..<contentEnd])
                segments.append(try parsePlaceholder(inside))
                i = template.index(contentEnd, offsetBy: 2)
            } else {
                literal.append(template[i])
                i = template.index(after: i)
            }
        }

        if !literal.isEmpty {
            segments.append(.literal(literal))
        }
        return segments
    }

    /// Finds the index of the `}}` that closes a placeholder, respecting quoted args
    /// so `}}` inside `"..."` or `'...'` is treated as literal. Returns the index of
    /// the first `}` of the closing pair; caller advances past `}}`.
    ///
    /// Backslash-escape handling uses parity counting: a quote is treated as escaped
    /// only when preceded by an odd number of backslashes (so `\\"` correctly closes
    /// after the literal backslash, while `\"` does not).
    private static func findPlaceholderEnd(
        in template: String,
        from start: String.Index
    ) -> String.Index? {
        var i = start
        var insideQuote: Character? = nil
        var consecutiveBackslashes = 0
        while i < template.endIndex {
            let c = template[i]
            if let quote = insideQuote {
                if c == quote && consecutiveBackslashes % 2 == 0 {
                    insideQuote = nil
                }
            } else if c == "\"" || c == "'" {
                insideQuote = c
            } else if c == "}" {
                let nextIdx = template.index(after: i)
                if nextIdx < template.endIndex && template[nextIdx] == "}" {
                    return i
                }
            }
            consecutiveBackslashes = (c == "\\") ? consecutiveBackslashes + 1 : 0
            i = template.index(after: i)
        }
        return nil
    }

    /// Parses placeholder body (inside `{{...}}`) into variable name + filter chain.
    /// Examples:
    /// - `result` → variable: "result", filters: []
    /// - `result|shell` → variable: "result", filters: [shell]
    /// - `result|llm:"summarize"|json` → variable: "result", filters: [llm("summarize"), json]
    private static func parsePlaceholder(_ inside: String) throws -> Segment {
        let parts = try splitTopLevel(inside, on: "|")
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !trimmed.isEmpty else {
            return .placeholder(variable: "", filters: [])
        }
        let varName = trimmed[0]
        let filters = try trimmed.dropFirst().map { try parseFilterCall($0) }
        return .placeholder(variable: varName, filters: filters)
    }

    /// Splits a string on `separator` at the top level, ignoring quoted regions.
    /// Tracks consecutive-backslash parity so `\\"` (escaped backslash + quote)
    /// is correctly treated as a quote boundary, while `\"` (escaped quote) is not.
    private static func splitTopLevel(_ s: String, on separator: Character) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var insideQuote: Character? = nil
        var consecutiveBackslashes = 0
        for c in s {
            if let q = insideQuote {
                if c == q && consecutiveBackslashes % 2 == 0 {
                    insideQuote = nil
                }
                current.append(c)
            } else if c == "\"" || c == "'" {
                insideQuote = c
                current.append(c)
            } else if c == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
            consecutiveBackslashes = (c == "\\") ? consecutiveBackslashes + 1 : 0
        }
        if insideQuote != nil {
            throw FilterError.parseError("unclosed quote in placeholder")
        }
        parts.append(current)
        return parts
    }

    /// Parses a single filter invocation: `filter:"arg1","arg2"` or `filter:80` or `filter`.
    private static func parseFilterCall(_ s: String) throws -> FilterCall {
        guard !s.isEmpty else {
            throw FilterError.parseError("empty filter in placeholder (stray `|`?)")
        }
        guard let colonIdx = s.firstIndex(of: ":") else {
            return FilterCall(name: s, args: [])
        }
        let name = String(s[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let argsString = String(s[s.index(after: colonIdx)...])
        let argParts = try splitTopLevel(argsString, on: ",")
        let args = argParts.map { unquote($0.trimmingCharacters(in: .whitespaces)) }
        return FilterCall(name: name, args: args)
    }

    /// Strips matching outer `"..."` or `'...'` quotes and resolves common escape
    /// sequences (`\"`, `\'`, `\\`, `\n`, `\t`). Single-pass scanner so escape
    /// ordering doesn't bite (unlike chained string-replace).
    private static func unquote(_ s: String) -> String {
        guard s.count >= 2,
              let first = s.first,
              let last = s.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else {
            return s
        }
        let inner = s.dropFirst().dropLast()
        var result = ""
        var i = inner.startIndex
        while i < inner.endIndex {
            let c = inner[i]
            let nextIdx = inner.index(after: i)
            if c == "\\" && nextIdx < inner.endIndex {
                let next = inner[nextIdx]
                switch next {
                case "\"", "'", "\\":
                    result.append(next)
                    i = inner.index(i, offsetBy: 2)
                    continue
                case "n":
                    result.append("\n")
                    i = inner.index(i, offsetBy: 2)
                    continue
                case "t":
                    result.append("\t")
                    i = inner.index(i, offsetBy: 2)
                    continue
                default:
                    // Unknown escape — pass through both chars literally.
                    result.append(c)
                    i = nextIdx
                    continue
                }
            }
            result.append(c)
            i = nextIdx
        }
        return result
    }
}

// MARK: - Filter Protocol

/// A pluggable filter applied to a value during template rendering. Sync filters
/// (raw, shell, json, url_encode) complete instantly under the async wrapper;
/// `|llm` is the only genuinely async filter in v1.
protocol Filter {
    var name: String { get }
    func apply(_ input: String, args: [String], sourceBundleId: String?) async throws -> String
}

// MARK: - Sync Filters

/// `|raw` — pass-through with no escaping. User is responsible for the result being safe.
struct RawFilter: Filter {
    let name = "raw"
    func apply(_ input: String, args: [String], sourceBundleId: String?) async throws -> String {
        return input
    }
}

/// `|shell` — wrap in single quotes and escape internal single quotes for `/bin/zsh -c`.
/// Empty input → `''`. The classic `'\''`-style escape: close the wrapping quote,
/// emit an escaped single quote, reopen the wrapping quote. Bash-safe for any input.
struct ShellFilter: Filter {
    let name = "shell"
    func apply(_ input: String, args: [String], sourceBundleId: String?) async throws -> String {
        let escaped = input.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

/// `|json` — JSON string-escape the input. Returns the inner content WITHOUT outer
/// quotes, so the user supplies the surrounding `"..."` in their template:
/// `{"text": "{{result|json}}"}`. Handles unicode, control chars, embedded quotes,
/// and backslashes via `JSONEncoder` (the canonical Foundation escaper).
struct JsonFilter: Filter {
    let name = "json"
    func apply(_ input: String, args: [String], sourceBundleId: String?) async throws -> String {
        // Encode as a single-element array so we can strip `[` `"` … `"` `]` and
        // recover the inner JSON-string-content. Encoding a bare String would
        // require a top-level non-fragment workaround; the array path is simpler.
        let data = try JSONEncoder().encode([input])
        guard let json = String(data: data, encoding: .utf8), json.count >= 4 else {
            throw TemplateEngine.FilterError.badArgument(
                "could not JSON-encode input",
                filter: "json"
            )
        }
        // json is `["..."]` — drop `["` from the front and `"]` from the back.
        return String(json.dropFirst(2).dropLast(2))
    }
}

/// `|url_encode` — percent-encode using RFC 3986 unreserved characters only.
/// Matches JavaScript's `encodeURIComponent()`. Safe for embedding in any URL
/// component (query value, path segment, fragment) without breaking surrounding
/// structure: `&`, `=`, `?`, `/`, `#` all get encoded.
///
/// Note: `Foundation.urlQueryAllowed` would *not* encode `=` or `&` (they're
/// reserved for query-string syntax), which is wrong when the user's value
/// contains them — e.g. `result = "a=1&b=2"` substituted into
/// `?q={{result|url_encode}}&other=…` would otherwise break `other` into a
/// separate parameter. We encode the unreserved-only set instead.
struct UrlEncodeFilter: Filter {
    let name = "url_encode"

    /// RFC 3986 unreserved characters — `A-Z a-z 0-9 - . _ ~`. Everything else
    /// gets percent-encoded.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    /// Also called directly by the non-chain url-action path in
    /// `ActionListWindow`, so both execution paths encode identically.
    static func encode(_ input: String) -> String {
        input.addingPercentEncoding(withAllowedCharacters: unreserved) ?? input
    }

    func apply(_ input: String, args: [String], sourceBundleId: String?) async throws -> String {
        return Self.encode(input)
    }
}

// MARK: - Async Filters

/// `|llm:"directive"` — run the input through Cai's configured LLM with `directive`
/// as the system prompt. Honors per-app Context Snippets when `sourceBundleId` is
/// provided. Headline filter for v1 — the feature that makes Cai's templates a
/// programmable LLM pipeline rather than just escaping with extra steps.
///
/// **Provider:** always `CaiSettings.modelProvider`. No `model:` arg in v1.
/// **Streaming:** none — filter is blocking; the destination needs the full result
/// before it runs.
/// **Errors:** maps `MLXInferenceError.busy` to `FilterError.busy` and any other
/// `LLMError` to `FilterError.llmFailed`.
struct LLMFilter: Filter {
    let name = "llm"
    func apply(_ input: String, args: [String], sourceBundleId: String?) async throws -> String {
        guard let directive = args.first, !directive.isEmpty else {
            throw TemplateEngine.FilterError.badArgument(
                "missing directive (use |llm:\"your instruction\")",
                filter: "llm"
            )
        }

        // Frame the LLM for filter-style use: output the raw result, nothing else.
        // The user-supplied directive specifies the actual task on the next line.
        let systemPrompt = """
            Output ONLY the result of the user's instruction. No preamble, no explanations, \
            no quotes around the output — your response is substituted directly into a \
            template, where surrounding text and quoting are already handled. Plain text \
            only — no markdown syntax.

            Instruction: \(directive)
            """

        // Resolve "About You" + per-app Context Snippet on the main actor (matches
        // the codebase convention for CaiSettings + ContextSnippetsManager access).
        let aboutYou = await MainActor.run { CaiSettings.shared.aboutYou }
        let snippet: ContextSnippet? = await MainActor.run {
            ContextSnippetsManager.shared.snippet(forBundleId: sourceBundleId)
        }

        let messages = LLMService.buildMessages(
            systemPrompt: systemPrompt,
            userPrompt: input,
            aboutYou: aboutYou,
            snippet: snippet
        )

        do {
            let response = try await LLMService.shared.generateWithMessages(messages)
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch MLXInferenceError.busy {
            throw TemplateEngine.FilterError.busy
        } catch let llmError as LLMError {
            throw TemplateEngine.FilterError.llmFailed(
                llmError.errorDescription ?? "LLM failed"
            )
        } catch {
            // Unexpected error type (e.g. MLXInferenceError.modelNotLoaded). Map to
            // llmFailed so the caller's toast shows something useful.
            throw TemplateEngine.FilterError.llmFailed(error.localizedDescription)
        }
    }
}
