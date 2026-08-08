import XCTest
import CaiActionCore
@testable import Cai

/// Which sinks may see a secret, and what a secret looks like when it gets there.
///
/// This is the security boundary of the feature, so it is table-driven and states
/// the negative cases first. The one that matters most is the prompt: prompts
/// render through the same engine as webhook headers and share `Context.raw`, so
/// nothing about the context distinguishes "send this to a model" from "send this
/// to an API". Only the call site's `SecretAccess` does.
final class SecretPolicyTests: XCTestCase {

    private let token = SecretValue("sk-live-0123456789")
    private var access: TemplateEngine.SecretAccess {
        TemplateEngine.SecretAccess(values: ["NOTION_API_TOKEN": token])
    }

    // MARK: - Refusal

    func testASinkThatDidNotOptInRefuses() async {
        // nil access is the default, which is what makes prompts safe without
        // every prompt call site having to remember anything.
        for context in [TemplateEngine.Context.raw, .shell, .json, .url] {
            do {
                _ = try await TemplateEngine.render(
                    "Summarize using {{secrets.NOTION_API_TOKEN}}",
                    vars: ["result": "x"],
                    context: context,
                    secrets: nil
                )
                XCTFail("\(context) resolved a secret without opting in")
            } catch TemplateEngine.FilterError.secretNotAllowed(let name) {
                XCTAssertEqual(name, "NOTION_API_TOKEN")
            } catch {
                XCTFail("wrong error for \(context): \(error)")
            }
        }
    }

    func testRefusalIsLoudRatherThanEmpty() async {
        // The failure that must not happen: an action that looks like it worked
        // and quietly sent no credential.
        do {
            let rendered = try await TemplateEngine.render(
                "curl -H \"Authorization: Bearer {{secrets.NOTION_API_TOKEN}}\" https://api.notion.com",
                vars: [:],
                context: .shell,
                secrets: nil
            )
            XCTFail("rendered instead of throwing: \(rendered)")
        } catch is TemplateEngine.FilterError {
            // correct
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testAMissingSecretIsNamedRatherThanSubstitutedEmpty() async {
        do {
            _ = try await TemplateEngine.render(
                "echo {{secrets.NO_SUCH_SECRET}}",
                vars: [:],
                context: .shell,
                secrets: access
            )
            XCTFail("resolved a secret that does not exist")
        } catch TemplateEngine.FilterError.unknownSecret(let name) {
            XCTAssertEqual(name, "NO_SUCH_SECRET")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testABrokenNameInTheNamespaceIsLoud() async {
        // `{{secrets.lowercase}}` is a secret reference written wrong, not an
        // unknown ordinary variable, so it must not render as empty.
        do {
            _ = try await TemplateEngine.render(
                "echo {{secrets.notion_token}}",
                vars: [:],
                context: .shell,
                secrets: nil
            )
            XCTFail("a malformed secret reference rendered")
        } catch TemplateEngine.FilterError.parseError {
            // correct
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - The filter allowlist

    func testTheLLMFilterCannotBeAppliedToASecret() async {
        do {
            _ = try await TemplateEngine.render(
                "{{secrets.NOTION_API_TOKEN|llm:\"describe this\"}}",
                vars: [:],
                context: .shell,
                secrets: access
            )
            XCTFail("a secret went through |llm")
        } catch TemplateEngine.FilterError.secretThroughFilter(let name, let filter) {
            XCTAssertEqual(name, "NOTION_API_TOKEN")
            XCTAssertEqual(filter, "llm")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTheAllowlistNeverContainsLLM() {
        XCTAssertEqual(TemplateEngine.filtersAllowedOnSecrets, ["json", "url_encode", "raw"])
        XCTAssertFalse(TemplateEngine.filtersAllowedOnSecrets.contains("llm"), "the whole point")
    }

    func testAnUnknownFilterOnASecretIsRefusedNotLookedUp() async {
        do {
            _ = try await TemplateEngine.render(
                "{{secrets.NOTION_API_TOKEN|exfiltrate}}",
                vars: [:],
                context: .shell,
                secrets: access
            )
            XCTFail("an unknown filter was allowed on a secret")
        } catch TemplateEngine.FilterError.secretThroughFilter(_, let filter) {
            XCTAssertEqual(filter, "exfiltrate", "refused by the allowlist before the registry is consulted")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAnEscapingFilterOnASecretIsRefusedGently() async {
        // |json cannot apply to a value that never enters the output; the error
        // says so instead of pretending to escape something.
        do {
            _ = try await TemplateEngine.render(
                "echo {{secrets.NOTION_API_TOKEN|json}}",
                vars: [:],
                context: .shell,
                secrets: access
            )
            XCTFail("an escaping filter was applied to an environment reference")
        } catch TemplateEngine.FilterError.badArgument(_, let filter) {
            XCTAssertEqual(filter, "json")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testRawIsANoOpOnASecret() async throws {
        // Docs teach |raw as "no escaping", which is what an environment
        // reference already is. Refusing it would only generate support noise.
        let rendered = try await TemplateEngine.render(
            "echo {{secrets.NOTION_API_TOKEN|raw}}",
            vars: [:],
            context: .shell,
            secrets: access
        )
        XCTAssertTrue(rendered.hasSuffix("\"$CAI_SECRET_NOTION_API_TOKEN\""))
    }

    // MARK: - Shell: the value never enters the command

    func testAShellCommandGetsAnEnvironmentReferenceNotTheValue() async throws {
        let rendered = try await TemplateEngine.render(
            "curl -H \"Authorization: Bearer {{secrets.NOTION_API_TOKEN}}\" https://api.notion.com",
            vars: [:],
            context: .shell,
            secrets: access
        )

        XCTAssertFalse(rendered.contains(token.raw), "the value reached argv")
        XCTAssertTrue(rendered.contains("\"$CAI_SECRET_NOTION_API_TOKEN\""))
    }

    func testTheEnvironmentReferenceIsQuotedSoASpaceCannotSplitIt() async throws {
        let rendered = try await TemplateEngine.render(
            "echo {{secrets.NOTION_API_TOKEN}}",
            vars: [:],
            context: .shell,
            secrets: access
        )
        XCTAssertTrue(rendered.hasSuffix("\"$CAI_SECRET_NOTION_API_TOKEN\""))
    }

    func testTheShellSafetyFilterIsNotAppliedToAnEnvironmentReference() async throws {
        // |shell would single-quote it, and '$CAI_SECRET_X' does not expand.
        let rendered = try await TemplateEngine.render(
            "echo {{secrets.NOTION_API_TOKEN}}",
            vars: [:],
            context: .shell,
            secrets: access
        )
        XCTAssertFalse(rendered.contains("'$CAI_SECRET_NOTION_API_TOKEN'"))
    }

    // MARK: - Single quotes: refuse rather than misfire

    func testAReferenceInsideSingleQuotesIsRefused() async {
        // 'Bearer "$CAI_SECRET_X"' would send the literal text as the
        // credential: a silent 401 the user cannot diagnose. Loud instead.
        do {
            _ = try await TemplateEngine.render(
                "curl -H 'Authorization: Bearer {{secrets.NOTION_API_TOKEN}}' https://api.notion.com",
                vars: [:],
                context: .shell,
                secrets: access
            )
            XCTFail("a reference inside single quotes rendered")
        } catch TemplateEngine.FilterError.secretInSingleQuotes(let name) {
            XCTAssertEqual(name, "NOTION_API_TOKEN")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAnApostropheInsideDoubleQuotesDoesNotFalsePositive() async throws {
        // "it's" must not count as an opened single quote.
        let rendered = try await TemplateEngine.render(
            "echo \"it's here:\" {{secrets.NOTION_API_TOKEN}}",
            vars: [:],
            context: .shell,
            secrets: access
        )
        XCTAssertTrue(rendered.hasSuffix("\"$CAI_SECRET_NOTION_API_TOKEN\""))
    }

    func testAClosedSingleQuoteBeforeTheReferenceIsFine() async throws {
        let rendered = try await TemplateEngine.render(
            "echo 'prefix' {{secrets.NOTION_API_TOKEN}}",
            vars: [:],
            context: .shell,
            secrets: access
        )
        XCTAssertTrue(rendered.hasSuffix("\"$CAI_SECRET_NOTION_API_TOKEN\""))
    }

    func testQuoteStateTracking() {
        let cases: [(String, Bool, String)] = [
            ("", false, "empty"),
            ("echo ", false, "no quotes"),
            ("echo '", true, "open single"),
            ("echo 'a'", false, "closed single"),
            ("echo \"it's\" ", false, "apostrophe inside double quotes"),
            ("echo \"a\" '", true, "double closed, single open"),
            ("echo \\' ", false, "escaped quote outside quotes"),
            ("echo 'can\\'", false, "backslash inside single quotes does not escape; the quote closes"),
            ("echo \"\\\"\" '", true, "escaped double quote inside double quotes, then open single"),
        ]
        for (prefix, expected, why) in cases {
            XCTAssertEqual(TemplateEngine.endsInsideSingleQuote(prefix), expected, "\(prefix): \(why)")
        }
    }

    // MARK: - Ordinary variables are untouched

    func testLowercaseVariablesBehaveExactlyAsBefore() async throws {
        let rendered = try await TemplateEngine.render(
            "echo {{result}}",
            vars: ["result": "hello"],
            context: .shell,
            secrets: nil
        )
        XCTAssertEqual(rendered, "echo 'hello'")
    }

    func testUppercaseVariablesAreOrdinaryVariables() async throws {
        // The regression the `secrets.` namespace exists to prevent: users have
        // setup fields named API_KEY, and extensions can define any key. Those
        // placeholders must keep resolving from vars exactly as before.
        let rendered = try await TemplateEngine.render(
            "Bearer {{API_KEY}}",
            vars: ["API_KEY": "field-value"],
            context: .raw,
            secrets: nil
        )
        XCTAssertEqual(rendered, "Bearer field-value")
    }

    func testAnUnknownVariableStillResolvesToEmptyWhateverItsCase() async throws {
        // Deliberately unchanged: templates get copied between contexts and a
        // stray {{title}} or {{RESULT}} should not kill the action. Only the
        // secrets namespace is the exception.
        let rendered = try await TemplateEngine.render(
            "echo [{{title}}][{{RESULT}}]",
            vars: [:],
            context: .raw,
            secrets: nil
        )
        XCTAssertEqual(rendered, "echo [][]")
    }
}
