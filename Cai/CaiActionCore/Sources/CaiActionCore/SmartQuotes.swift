import Foundation

extension String {
    /// Replaces macOS "smart quotes" (curly typographic quotes inserted
    /// automatically by NSTextView / SwiftUI TextField when Substitutions →
    /// Smart Quotes is on) with straight ASCII quotes. Shell (zsh), URL
    /// schemes, JSON, and AppleScript all reject curly quotes — a user
    /// pasting or typing `'{{result}}'` into a Shortcut or Destination
    /// template gets `'{{result}}'`, which fails at runtime with an
    /// unhelpful "command not found" or parse error.
    ///
    /// Applied at save-time in ShortcutsManagementView and
    /// DestinationsManagementView, and to every authored action value the
    /// validator normalizes (agents paste from chat transcripts, which carry
    /// curly quotes just as often as a human does). Not applied to user
    /// clipboard text — only to template definitions where curly quotes have
    /// no valid use.
    ///
    /// Lives in CaiActionCore rather than the app so the helper normalizes
    /// identically before it ever writes a pending change.
    public func normalizingSmartQuotes() -> String {
        self
            .replacingOccurrences(of: "\u{2018}", with: "'")   // ' left single
            .replacingOccurrences(of: "\u{2019}", with: "'")   // ' right single
            .replacingOccurrences(of: "\u{201A}", with: "'")   // ‚ low single
            .replacingOccurrences(of: "\u{201B}", with: "'")   // ‛ reversed single
            .replacingOccurrences(of: "\u{201C}", with: "\"")  // " left double
            .replacingOccurrences(of: "\u{201D}", with: "\"")  // " right double
            .replacingOccurrences(of: "\u{201E}", with: "\"")  // „ low double
            .replacingOccurrences(of: "\u{201F}", with: "\"")  // ‟ reversed double
    }

    /// Strips control characters (everything in Unicode category Cc plus the
    /// zero-width / bidi formatting characters in Cf) while keeping the
    /// newlines and tabs that legitimately appear inside prompts and shell
    /// templates.
    ///
    /// This is a legibility defense, not an escaping one: an authored name
    /// carrying `\u{202E}` (right-to-left override) or a bare `\r` renders in
    /// the approval sheet as something other than what would actually be
    /// saved, which is precisely the trick a malicious proposal would use to
    /// make a shell payload read as harmless.
    /// `.newlines` as well as `.controlCharacters`, because they do not
    /// overlap where it matters. U+2028 LINE SEPARATOR and U+2029 PARAGRAPH
    /// SEPARATOR are categories Zl and Zp, so `.controlCharacters` (Cc plus
    /// Cf) lets them through, yet CoreText breaks a line on both. That gap is
    /// load-bearing: `String.components(separatedBy: "\n")` does not split on
    /// them, so a value carrying one stays a single logical line and gets a
    /// single `│ ` gutter, while `Text` renders it as two, and the second has
    /// no gutter at the x-position where structure lines begin. The whole
    /// point of the gutter is that one string line is one rendered line.
    public func strippingControlCharacters(keepingNewlines: Bool) -> String {
        String(unicodeScalars.filter { scalar in
            if keepingNewlines, scalar == "\n" || scalar == "\t" { return true }
            return !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
        })
    }
}
