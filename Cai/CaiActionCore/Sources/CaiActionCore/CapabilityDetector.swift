import Foundation

/// What an action will touch, derived from the action alone.
///
/// Pure, and folded over the same `ChainWalk` the escalation classifier uses, so
/// the chips and the callouts can never describe different chains.
///
/// **The rule this file exists to hold.** Every capability returned has a source
/// Cai can point at: the action's type, its resolved chain, a `{{secrets.NAME}}`
/// reference, or a URL parsed without guessing. Where Cai cannot bound what
/// happens — a freeform shell body above all — the answer is the honest floor
/// plus `isExhaustive == false`, never a specific-but-possibly-wrong claim.
/// Under-detection is false reassurance: a chip row that looks complete over an
/// action that does more is worse than no chip row at all, because it actively
/// lulls. When in doubt, claim less and say the list is open.
public enum CapabilityDetector {

    /// Every capability an action reaches, in fixed render order.
    public static func capabilities(
        for action: ActionSnapshot,
        known: KnownActions
    ) -> [Capability] {
        let reach = ChainWalk.reachable(from: action, known: known)
        var found: Set<Capability> = []

        for (current, _) in reach.actions {
            switch current.type {
            case .shell:
                // The floor, and all of it. No host is ever parsed out of a
                // shell body and no `tell application` either: both are
                // arbitrary text with substitution, pipes and subshells around
                // them, and a precise-looking chip derived from one line of it
                // would be a lie on a security surface.
                found.insert(.runsShellCommand)
            case .url:
                found.formUnion(urlCapabilities(template: current.value))
            case .prompt:
                found.insert(.runsAI)
            }

            if current.autoReplaceSelection { found.insert(.replacesSelection) }

            // Names only. The scan runs over the action values reachable from
            // here — exactly the templates the escalation classifier scans, so
            // the secrets chip and the secrets callout always agree. Destination
            // templates are deliberately not scanned: their configs never cross
            // into this package, and claiming coverage the architecture forbids
            // would be the over-claim this file exists to prevent.
            for name in SecretReference.names(in: current.value) {
                found.insert(.usesSecret(name: name))
            }
        }

        if reach.hasInlineLLMStep { found.insert(.runsAI) }

        for leaf in reach.leaves {
            switch leaf {
            case .appleShortcut:
                found.insert(.runsAppleShortcut)
            case .builtIn:
                // Chainable built-ins are leaf LLM transforms.
                found.insert(.runsAI)
            case .unresolved(let name):
                found.insert(.runsUninstalled(name: name))
            case .destination(let destination):
                found.formUnion(destinationCapabilities(destination))
            }
        }

        return found.sorted {
            $0.sortOrder == $1.sortOrder ? $0.sortKey < $1.sortKey : $0.sortOrder < $1.sortOrder
        }
    }

    // MARK: - Destinations

    /// A destination's capabilities, by identity where Cai owns it and by kind
    /// where it does not.
    private static func destinationCapabilities(_ destination: DestinationSummary) -> Set<Capability> {
        // Cai's own built-ins are known by role, so their chips are exact
        // without parsing anything. Role comes from a fixed UUID in the app,
        // never from the display name: names are editable and not unique, so a
        // user-authored script named "Save to Notes" must not borrow the
        // built-in's chip.
        if let role = destination.builtInRole {
            switch role {
            case .mailDraft: return [.opensMailDraft]
            case .notes: return [.writesTo(app: "Notes")]
            case .reminders: return [.writesTo(app: "Reminders")]
            case .replaceSelection: return [.replacesSelection]
            case .clipboard: return [.copiesToClipboard]
            }
        }

        switch destination.kind {
        case .shell:
            return [.runsShellCommand]
        case .applescript:
            // A user-authored AppleScript. Coarse and open-ended on purpose:
            // the `tell application` grammar has enough hostile forms (`tell
            // app`, `tell application id`, a tell through a variable, `using
            // terms from`, a tell inside a string literal, `do shell script`)
            // that a parser would be precise exactly where it is wrong. The
            // unbounded chip is the true statement.
            return [.runsAppleScript]
        case .webhook:
            // No parseable host is still a send. Returning nothing here left an
            // empty chip row claiming exhaustiveness beside a callout warning
            // about a URL send.
            guard let host = destination.networkTarget else { return [.sendsToUnknownHost] }
            return [.sendsToHost(host)]
        case .deeplink:
            guard let scheme = destination.networkTarget else { return [.sendsToUnknownHost] }
            return [.opensScheme(scheme)]
        case .pasteBack:
            return [.replacesSelection]
        case .clipboardCopy:
            return [.copiesToClipboard]
        }
    }

    // MARK: - URL actions

    /// A url action's capabilities.
    ///
    /// One verb rule across the whole app: **"sends" means the selection leaves
    /// the Mac.** A `%s` in the template embeds the selection in the request, so
    /// that is `sendsToHost`; a template without one merely opens a fixed
    /// address, so it is `opensHost`. The distinction carries the sheet's orange
    /// callout onto the surfaces that have no callout, like the Settings list,
    /// where the chip is the only claim being made.
    static func urlCapabilities(template: String) -> Set<Capability> {
        // An unparseable or templated authority means the action still opens a
        // URL — the escalation classifier says so — but Cai cannot name where.
        // The honest answer is the open-ended chip, never an empty row.
        guard let host = host(inURLTemplate: template) else { return [.sendsToUnknownHost] }
        return embedsSelection(inURLTemplate: template) ? [.sendsToHost(host)] : [.opensHost(host)]
    }

    /// Whether a url action's template carries the selection into the request.
    ///
    /// `%s` is the documented spelling and the only one the direct ⌥C path
    /// substitutes (`ActionListWindow`). But run as a CHAIN step the same value
    /// goes through `TemplateEngine` with the piped text bound to `result`
    /// (`ChainExecutor`), so `https://x.com/?q={{result}}` sends the selection
    /// with no `%s` anywhere. A `%s`-only test therefore under-claims on the
    /// chain path — it would say "Opens x.com" about an action that uploads
    /// what you selected.
    ///
    /// So any placeholder counts. That over-reports for something like
    /// `?v={{secrets.KEY}}`, which sends a secret rather than the selection —
    /// still a send, still the conservative direction, and "sends" is the claim
    /// we would rather be wrong about on an approval surface.
    ///
    /// Shared with `ApprovalClassifier` rather than duplicated, so the chip and
    /// the callout cannot disagree about whether a URL is a send.
    public static func embedsSelection(inURLTemplate template: String) -> Bool {
        template.contains("%s") || template.contains("{{")
    }

    /// The host of a `%s`-templated URL, or nil when it cannot be known.
    ///
    /// This is the one security-sensitive parser here: a wrong host chip is a
    /// lie on an approval surface, so it is written to degrade to nil rather
    /// than to guess. Nil is safe — the payload is on screen and the type still
    /// says the action opens a URL.
    ///
    /// - Parsed with `URLComponents`, never by slicing on `//` and `/`. That is
    ///   what makes `https://github.com@evil.com/%s` report `evil.com`: the part
    ///   before the `@` is userinfo, and a hand-rolled split reads it as the
    ///   host, which is precisely the trick a malicious template would use.
    /// - Refused when a substitution appears at or before the end of the
    ///   authority, so `https://%s.example.com/` and `https://{{host}}/x` chip
    ///   nothing at all: the host is not known until runtime, and half of it is
    ///   not a fact.
    /// - `http`/`https` only. Anything else is not a web address and gets no
    ///   host claim.
    /// - Non-ASCII hosts are refused rather than rendered. A Unicode homograph
    ///   (`аpple.com` with a Cyrillic а) drawn in Cai's own voice at 10pt is a
    ///   worse outcome than no chip, and IDNA-folding it correctly is not MLP
    ///   work.
    public static func host(inURLTemplate template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both parsers must agree, or no host is claimed.
        //
        // The chip is read by a human deciding whether to approve, but the thing
        // that actually opens is `URL(string:)` in `ActionListWindow` and
        // `ChainExecutor`. `URLComponents` and `URL` are different Foundation
        // parsers with different lineages (RFC 3986 vs the WHATWG-leaning modern
        // one), and naming a host from one while the other does the opening is
        // an unwritten assumption. Differential fuzzing found 14 real
        // divergences on the current OS — unicode slash lookalikes that URL
        // folds into another registrable domain (`a.com⁄b.com` →
        // `a.xn--comb-2g7a.com`), punycode that URLComponents DECODES to a
        // Cyrillic homograph, empty authorities, bracketed IPv6 — all pinned in
        // `testHostExtractionRefusesRatherThanGuesses`.
        //
        // A targeted 409-case hunt for the dangerous shape — both parsers
        // returning DIFFERENT hosts that each pass the ASCII filter below —
        // found none, so the filter alone was already sufficient here and every
        // known divergence lands where it already refuses. This check is
        // therefore belt to that brace, and it is worth keeping for the case
        // that cannot be tested from a dev machine: the deployment floor is
        // macOS 14, where `URLComponents` (CFURL) and `URL` (swift-foundation)
        // have different lineages than they do on current systems.
        //
        // The assumption is enforced rather than trusted, so on any OS where
        // they disagree the reader gets no host chip instead of a wrong one.
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              URL(string: trimmed)?.host?.lowercased() == host
        else { return nil }

        // Makes the slice below safe by construction rather than by inference:
        // a non-nil host implies a literal `scheme://` prefix today, but that is
        // the macOS URL parser's business and not a promise to build on.
        guard trimmed.dropFirst(scheme.count).hasPrefix("://") else { return nil }

        // A substitution inside the authority means the host is unknown. Locate
        // the authority by its end (the first `/`, `?` or `#` after the scheme)
        // rather than by re-parsing, and refuse if any placeholder starts before
        // it.
        let afterScheme = trimmed.dropFirst(scheme.count + 3) // "://"
        let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.contains("%s"), !authority.contains("{{") else { return nil }

        guard host.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }) else {
            return nil
        }
        return host
    }
}
