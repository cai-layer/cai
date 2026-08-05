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
    private var values: [String: SecretValue] { ["NOTION_API_TOKEN": token] }

    // MARK: - Refusal

    func testASinkThatDidNotOptInRefuses() async {
        // nil access is the default, which is what makes prompts safe without
        // every prompt call site having to remember anything.
        for context in [TemplateEngine.Context.raw, .shell, .json, .url] {
            do {
                _ = try await TemplateEngine.render(
                    "Summarize using {{NOTION_API_TOKEN}}",
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
                "curl -H \"Authorization: Bearer {{NOTION_API_TOKEN}}\" https://api.notion.com",
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
                "echo {{NO_SUCH_SECRET}}",
                vars: [:],
                context: .shell,
                secrets: .environmentReference(values)
            )
            XCTFail("resolved a secret that does not exist")
        } catch TemplateEngine.FilterError.unknownSecret(let name) {
            XCTAssertEqual(name, "NO_SUCH_SECRET")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - The filter allowlist

    func testTheLLMFilterCannotBeAppliedToASecret() async {
        for access in [TemplateEngine.SecretAccess.substituted(values), .environmentReference(values)] {
            do {
                _ = try await TemplateEngine.render(
                    "{{NOTION_API_TOKEN|llm:\"describe this\"}}",
                    vars: [:],
                    context: .raw,
                    secrets: access
                )
                XCTFail("a secret went through |llm")
            } catch TemplateEngine.FilterError.secretThroughFilter(let name, let filter) {
                XCTAssertEqual(name, "NOTION_API_TOKEN")
                XCTAssertEqual(filter, "llm")
            } catch TemplateEngine.FilterError.badArgument {
                // environmentReference rejects any filter at all, which is stricter
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
    }

    func testTheAllowlistHoldsOnlyEscapingFilters() {
        XCTAssertEqual(TemplateEngine.filtersAllowedOnSecrets, ["json", "url_encode", "raw"])
        XCTAssertFalse(TemplateEngine.filtersAllowedOnSecrets.contains("llm"), "the whole point")
    }

    func testAnUnknownFilterOnASecretIsRefusedNotLookedUp() async {
        do {
            _ = try await TemplateEngine.render(
                "{{NOTION_API_TOKEN|exfiltrate}}",
                vars: [:],
                context: .raw,
                secrets: .substituted(values)
            )
            XCTFail("an unknown filter was allowed on a secret")
        } catch TemplateEngine.FilterError.secretThroughFilter(_, let filter) {
            XCTAssertEqual(filter, "exfiltrate", "refused by the allowlist before the registry is consulted")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Shell: the value never enters the command

    func testAShellCommandGetsAnEnvironmentReferenceNotTheValue() async throws {
        let rendered = try await TemplateEngine.render(
            "curl -H \"Authorization: Bearer {{NOTION_API_TOKEN}}\" https://api.notion.com",
            vars: [:],
            context: .shell,
            secrets: .environmentReference(values)
        )

        XCTAssertFalse(rendered.contains(token.raw), "the value reached argv, where ps can read it")
        XCTAssertTrue(rendered.contains("\"$CAI_SECRET_NOTION_API_TOKEN\""))
    }

    func testTheEnvironmentReferenceIsQuotedSoASpaceCannotSplitIt() async throws {
        let rendered = try await TemplateEngine.render(
            "echo {{NOTION_API_TOKEN}}",
            vars: [:],
            context: .shell,
            secrets: .environmentReference(values)
        )
        XCTAssertTrue(rendered.hasSuffix("\"$CAI_SECRET_NOTION_API_TOKEN\""))
    }

    func testTheShellSafetyFilterIsNotAppliedToAnEnvironmentReference() async throws {
        // |shell would single-quote it, and '$CAI_SECRET_X' does not expand.
        let rendered = try await TemplateEngine.render(
            "echo {{NOTION_API_TOKEN}}",
            vars: [:],
            context: .shell,
            secrets: .environmentReference(values)
        )
        XCTAssertFalse(rendered.contains("'$CAI_SECRET_NOTION_API_TOKEN'"))
    }

    // MARK: - Substitution, for the sinks that need the real value

    func testASubstitutedSecretCarriesTheValue() async throws {
        let rendered = try await TemplateEngine.render(
            "Authorization: Bearer {{NOTION_API_TOKEN}}",
            vars: [:],
            context: .raw,
            secrets: .substituted(values)
        )
        XCTAssertEqual(rendered, "Authorization: Bearer \(token.raw)")
    }

    func testASubstitutedSecretIsJSONEscapedInAJSONBody() async throws {
        let quoted = SecretValue("with\"quote")
        let rendered = try await TemplateEngine.render(
            "{\"token\": \"{{TOKEN}}\"}",
            vars: [:],
            context: .json,
            secrets: .substituted(["TOKEN": quoted])
        )
        XCTAssertTrue(rendered.contains("with\\\"quote"), "an unescaped quote would break the body: \(rendered)")
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

    func testAnUnknownLowercaseVariableStillResolvesToEmpty() async throws {
        // Deliberately unchanged: templates get copied between contexts and a
        // stray {{title}} should not kill the action. Secrets are the exception.
        let rendered = try await TemplateEngine.render(
            "echo [{{title}}]",
            vars: [:],
            context: .raw,
            secrets: nil
        )
        XCTAssertEqual(rendered, "echo []")
    }
}
