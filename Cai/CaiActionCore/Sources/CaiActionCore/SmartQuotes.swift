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
        mappingScalarsPreservingEmoji { scalar in
            if keepingNewlines, scalar == "\n" || scalar == "\t" { return scalar }
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            if CharacterSet.newlines.contains(scalar) { return nil }
            return scalar
        }
    }

    /// Maps `transform` over every scalar, except inside a grapheme cluster
    /// that renders as an emoji, which is kept as it is apart from trailing
    /// invisible padding.
    ///
    /// ZWJ is Cf, so a flat scalar filter removes it and an action named
    /// `"\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466} Family"` stores as three
    /// separate emoji. A flat *exemption* for ZWJ is not the answer either:
    /// ZWJ is invisible, so `"Sum\u{200D}marize"` would then render exactly
    /// like `"Summarize"` and reopen the impersonation this file exists to
    /// close.
    ///
    /// The discriminator is the grapheme cluster. Swift's grapheme breaking
    /// already knows the ZWJ inside a family emoji is structural (one
    /// `Character`) while the one in `"Sum\u{200D}marize"` is not, so no emoji
    /// table is needed and nothing here rots as Unicode adds sequences. A
    /// cluster counts as emoji when any of its scalars has the Unicode
    /// `Emoji_Presentation` property, which is true of the pictographs and
    /// false of digits and letters (so `"1\u{200D}2"` is not protected).
    ///
    /// Trailing joiners are still dropped: `"\u{1F468}\u{200D}"` is a
    /// complete cluster to the segmenter, but the joiner adds nothing to the
    /// glyph and would be invisible padding on a name. Variation selectors are
    /// kept, since `"\u{2709}\u{FE0F}"` legitimately ends with one.
    func mappingScalarsPreservingEmoji(
        _ transform: (Unicode.Scalar) -> Unicode.Scalar?
    ) -> String {
        var result = String.UnicodeScalarView()
        for character in self {
            guard character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) else {
                result.append(contentsOf: character.unicodeScalars.compactMap(transform))
                continue
            }
            var scalars = Array(character.unicodeScalars)
            while let last = scalars.last,
                  last.properties.isDefaultIgnorableCodePoint,
                  !last.properties.isVariationSelector {
                scalars.removeLast()
            }
            result.append(contentsOf: scalars)
        }
        return String(result)
    }
}

extension String {
    /// Folds a name down to what the user actually sees, so two names that
    /// render identically compare identically.
    ///
    /// `strippingControlCharacters` already removes Cc and Cf, which covers
    /// U+200B–200D, U+FEFF and the bidi overrides. Three classes survive it
    /// and each one lets an authored name impersonate an existing action on
    /// the approval sheet, and in the ⌥C list forever after:
    ///
    /// - **Default-ignorable non-Cf scalars.** U+3164 HANGUL FILLER and the
    ///   U+115F / U+1160 / U+FFA0 fillers are category Lo, U+17B4 / U+17B5 are
    ///   Mn. All render as nothing, none are Cf. Matched by the Unicode
    ///   `Default_Ignorable_Code_Point` property rather than a hand-kept list,
    ///   so a scalar added in a future Unicode revision is covered without a
    ///   code change.
    /// - **Variation selectors are kept.** They are default-ignorable, but
    ///   U+FE0F is what makes an emoji render as an emoji, so dropping it
    ///   would change a legitimate name's appearance rather than protect it.
    /// - **U+2800 BRAILLE PATTERN BLANK.** Category So and *not*
    ///   default-ignorable, because it legitimately renders as an empty
    ///   braille cell. In a one-line action name it is simply invisible, so it
    ///   is the one scalar this needs to name explicitly.
    /// - **Whitespace lookalikes.** `trimmingCharacters` only touches the
    ///   ends, so `"Send\u{00A0}Email"` renders pixel-identically to
    ///   `"Send Email"` and compares unequal. Every whitespace scalar becomes
    ///   an ASCII space so the mid-string case stops being a bypass.
    ///   `.whitespacesAndNewlines` rather than `.whitespaces` so this does not
    ///   depend on the caller having stripped newlines first: U+2028 and
    ///   U+2029 are Zl and Zp, so they are in neither `.controlCharacters`
    ///   nor `.whitespaces`. On the name path `strippingControlCharacters`
    ///   removes them before this runs, but a fold that is only correct
    ///   because of what its caller did first is a trap for the next reader.
    ///
    /// NFC first, so the stored name is byte-stable and a stacked-mark name
    /// counts its scalars after composition. It is not what closes the
    /// duplicate hole: Swift's `==` and `caseInsensitiveCompare` already
    /// compare under canonical equivalence, so `"Cafe\u{0301}"` and `"Café"`
    /// are already the same string to both. That is also why a pure NFD → NFC
    /// change raises no warning: the before and after are `==`.
    ///
    /// Names only. A chain step naming an invisible-padded action fails to
    /// resolve and already escalates as `chainsToUnknownAction`, which fails
    /// loud; a value is bounded by the pending-file byte cap and renders in a
    /// scrollable block, not a one-line row.
    public func foldingInvisibleScalars() -> String {
        return precomposedStringWithCanonicalMapping.mappingScalarsPreservingEmoji { scalar in
            if scalar == "\u{2800}" { return nil }
            let properties = scalar.properties
            if properties.isDefaultIgnorableCodePoint && !properties.isVariationSelector {
                return nil
            }
            return CharacterSet.whitespacesAndNewlines.contains(scalar) ? " " : scalar
        }
    }
}
