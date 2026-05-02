import XCTest
@testable import Cai

/// Tests for `String.normalizingSmartQuotes()` — the helper that converts
/// macOS-autocorrected curly quotes (\u{2018}\u{2019}\u{201C}\u{201D}) back to
/// straight ASCII quotes before user-authored shortcut/destination templates
/// are persisted.
///
/// macOS smart-quote autocorrect is on by default in text fields. zsh, URL
/// parsers, and most shells don't understand curly quotes, so a template that
/// looks correct visually fails at runtime with `command not found` or a
/// parse error. We strip them at save time.
///
/// Coverage:
/// - Each of the four curly chars individually
/// - Realistic shell / bash one-liners (the highest-stakes case — these get
///   executed verbatim)
/// - URL templates
/// - Natural-language prompts (curly quotes inside text are still OK to
///   normalize; LLMs handle either form)
/// - No-ops: text without smart quotes must round-trip unchanged
final class SmartQuoteNormalizationTests: XCTestCase {

    // MARK: - Individual character coverage

    func testLeftSingleQuote() {
        XCTAssertEqual("hello \u{2018}world".normalizingSmartQuotes(), "hello 'world")
    }

    func testRightSingleQuote() {
        XCTAssertEqual("world\u{2019}s end".normalizingSmartQuotes(), "world's end")
    }

    func testLeftDoubleQuote() {
        XCTAssertEqual("\u{201C}quoted".normalizingSmartQuotes(), "\"quoted")
    }

    func testRightDoubleQuote() {
        XCTAssertEqual("quoted\u{201D}".normalizingSmartQuotes(), "quoted\"")
    }

    // The implementation also handles four less-common variants used in
    // German/Czech typography and occasional rich-text paste. macOS
    // smart-quote autocorrect doesn't *produce* these, but they can arrive
    // via paste — and the implementation handles them, so the tests should
    // too.

    func testLowSingleQuote() {
        XCTAssertEqual("foo\u{201A}bar".normalizingSmartQuotes(), "foo'bar")
    }

    func testReversedSingleQuote() {
        XCTAssertEqual("foo\u{201B}bar".normalizingSmartQuotes(), "foo'bar")
    }

    func testLowDoubleQuote() {
        XCTAssertEqual("foo\u{201E}bar".normalizingSmartQuotes(), "foo\"bar")
    }

    func testReversedDoubleQuote() {
        XCTAssertEqual("foo\u{201F}bar".normalizingSmartQuotes(), "foo\"bar")
    }

    func testAllFourTogether() {
        let input  = "\u{2018}a\u{2019} and \u{201C}b\u{201D}"
        let expect = "'a' and \"b\""
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    // MARK: - No-op cases

    func testEmptyString() {
        XCTAssertEqual("".normalizingSmartQuotes(), "")
    }

    func testPlainTextWithNoQuotes() {
        XCTAssertEqual("just plain text".normalizingSmartQuotes(), "just plain text")
    }

    func testAlreadyStraightQuotes() {
        let s = "'single' and \"double\" stay as-is"
        XCTAssertEqual(s.normalizingSmartQuotes(), s)
    }

    func testNonQuoteUnicodeSurvives() {
        // Other Unicode characters (emoji, accents, em-dash) must NOT be touched.
        let s = "café — naïve 🎉"
        XCTAssertEqual(s.normalizingSmartQuotes(), s)
    }

    // MARK: - Shell / bash one-liners

    /// Shell shortcut with curly-quoted placeholder — the literal canonical
    /// failure case. After normalization this must be valid zsh.
    func testShellSingleQuotedResult() {
        let input  = "echo \u{2018}{{result}}\u{2019} | base64"
        let expect = "echo '{{result}}' | base64"
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    func testShellDoubleQuotedResult() {
        let input  = "say \u{201C}{{result}}\u{201D}"
        let expect = "say \"{{result}}\""
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    func testShellPipelineWithMultipleQuotes() {
        let input  = "echo \u{2018}{{result}}\u{2019} | tr \u{2018}[:lower:]\u{2019} \u{2018}[:upper:]\u{2019}"
        let expect = "echo '{{result}}' | tr '[:lower:]' '[:upper:]'"
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    /// Apostrophe inside a double-quoted bash string (smart-quote autocorrect
    /// produces \u{2019} for typed apostrophes).
    func testShellApostropheInDoubleQuotedString() {
        let input  = "echo \"it\u{2019}s working\""
        let expect = "echo \"it's working\""
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    func testShellGhCommand() {
        let input  = "/opt/homebrew/bin/gh issue create --title \u{201C}From Cai\u{201D} --body {{result}}"
        let expect = "/opt/homebrew/bin/gh issue create --title \"From Cai\" --body {{result}}"
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    func testShellAppendToFile() {
        let input  = "echo \u{201C}[$(date)] {{result}}\u{201D} >> ~/journal.md"
        let expect = "echo \"[$(date)] {{result}}\" >> ~/journal.md"
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    /// Multi-line bash script with mixed quoting — the kind of thing a user
    /// might paste from a blog post or AI chat.
    func testMultilineBashScript() {
        let input = """
        if [ \u{2018}{{result}}\u{2019} = \u{2018}prod\u{2019} ]; then
            echo \u{201C}deploying production\u{201D}
            curl -X POST \u{201C}https://api.example.com/deploy\u{201D}
        fi
        """
        let expect = """
        if [ '{{result}}' = 'prod' ]; then
            echo "deploying production"
            curl -X POST "https://api.example.com/deploy"
        fi
        """
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    func testShellWithEscapedQuotesInside() {
        // Bash escape sequence \" must be preserved verbatim; we only swap
        // the curly chars, never touch backslashes.
        let input  = "echo \u{201C}she said \\\"hi\\\"\u{201D}"
        let expect = "echo \"she said \\\"hi\\\"\""
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    // MARK: - URL templates

    func testURLTemplateWithSmartQuotes() {
        // %s placeholder URL action — quotes around the template are unusual
        // but should normalize cleanly if a user pastes them in.
        let input  = "https://google.com/search?q=\u{201C}%s\u{201D}"
        let expect = "https://google.com/search?q=\"%s\""
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    // MARK: - Prompts (LLM custom actions)

    func testNaturalLanguagePromptWithCurlyApostrophe() {
        // A user types "Don't summarize, just translate" — autocorrect
        // produces a curly apostrophe. LLMs handle either form, but
        // normalizing keeps the data uniform.
        let input  = "Don\u{2019}t summarize, just translate to German"
        let expect = "Don't summarize, just translate to German"
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    func testPromptWithQuotedExample() {
        let input  = "Rewrite using the phrase \u{201C}as soon as possible\u{201D}"
        let expect = "Rewrite using the phrase \"as soon as possible\""
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    func testPromptMixedSingleAndDouble() {
        let input  = "It\u{2019}s like \u{201C}magic\u{201D} for the team\u{2019}s workflow"
        let expect = "It's like \"magic\" for the team's workflow"
        XCTAssertEqual(input.normalizingSmartQuotes(), expect)
    }

    // MARK: - Idempotence

    /// Running twice must be a no-op on the second pass — protects against
    /// double-normalization if the helper is ever called from multiple sites.
    func testIdempotent() {
        let input = "echo \u{2018}{{result}}\u{2019} && say \u{201C}done\u{201D}"
        let once = input.normalizingSmartQuotes()
        let twice = once.normalizingSmartQuotes()
        XCTAssertEqual(once, twice)
    }
}
