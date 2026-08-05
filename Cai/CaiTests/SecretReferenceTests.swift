import XCTest
import CaiActionCore
@testable import Cai

/// Names, and finding references to them in a template.
final class SecretReferenceTests: XCTestCase {

    // MARK: - Names

    func testNameValidity() {
        let cases: [(String, Bool, String)] = [
            ("NOTION_API_TOKEN", true, "the ordinary case"),
            ("AB", true, "two characters is the floor"),
            ("A1_2", true, "digits and underscores after the first letter"),
            ("A", false, "one character"),
            ("", false, "empty"),
            ("notion_token", false, "lowercase, which is what ordinary variables look like"),
            ("Notion_Token", false, "mixed case"),
            ("1TOKEN", false, "leading digit"),
            ("_TOKEN", false, "leading underscore"),
            ("MY-TOKEN", false, "hyphen"),
            ("MY TOKEN", false, "space"),
            ("TOKEN!", false, "punctuation"),
            ("TÖKEN", false, "non-ASCII, which would not survive an environment variable"),
            (String(repeating: "A", count: 64), true, "at the length limit"),
            (String(repeating: "A", count: 65), false, "past the length limit"),
        ]

        for (name, expected, why) in cases {
            XCTAssertEqual(SecretReference.isValidName(name), expected, "\(name): \(why)")
        }
    }

    func testTheReservedVariableCannotBeShadowed() {
        // Ordinary variables are lowercase, so a secret can never collide with
        // `result` or with an MCP form key. This is the structural guarantee
        // behind the naming rule, so it is worth pinning.
        XCTAssertFalse(SecretReference.isValidName("result"))
        XCTAssertFalse(SecretReference.isValidName("repo_owner"))
    }

    func testRejectionsExplainThemselves() {
        XCTAssertNil(SecretReference.nameRejection("NOTION_API_TOKEN"))
        XCTAssertEqual(SecretReference.nameRejection(""), "Give the secret a name.")
        XCTAssertTrue(SecretReference.nameRejection("a")?.contains("two characters") == true)
        XCTAssertTrue(SecretReference.nameRejection("token")?.contains("upper-case letter") == true)
        XCTAssertTrue(SecretReference.nameRejection("MY-TOKEN")?.contains("underscores") == true)
        XCTAssertTrue(SecretReference.nameRejection(String(repeating: "A", count: 99))?.contains("64") == true)
    }

    // MARK: - Keychain accounts

    func testAccountRoundTrip() {
        let account = SecretReference.accountName(for: "NOTION_API_TOKEN")
        XCTAssertEqual(account, "cai_secret_NOTION_API_TOKEN")
        XCTAssertEqual(SecretReference.name(fromAccount: account), "NOTION_API_TOKEN")
    }

    func testTheModelAPIKeysAreNotMistakenForSecrets() {
        // They share the Keychain service, so the prefix is what separates them.
        for account in ["cai_apiKey", "cai_anthropicApiKey", "cai_openRouterApiKey"] {
            XCTAssertNil(SecretReference.name(fromAccount: account), account)
        }
    }

    func testAnAccountWithAnInvalidNameIsIgnored() {
        // Someone editing Keychain Access by hand cannot inject a name the rest
        // of the system would then treat as valid.
        XCTAssertNil(SecretReference.name(fromAccount: "cai_secret_lowercase"))
        XCTAssertNil(SecretReference.name(fromAccount: "cai_secret_"))
    }

    func testEnvironmentVariableName() {
        XCTAssertEqual(
            SecretReference.environmentVariable(for: "NOTION_API_TOKEN"),
            "CAI_SECRET_NOTION_API_TOKEN"
        )
    }

    // MARK: - Finding references

    func testFindingReferences() {
        let cases: [(String, Set<String>, String)] = [
            ("", [], "empty template"),
            ("echo hello", [], "no placeholders"),
            ("echo {{result}}", [], "an ordinary variable is not a secret"),
            ("echo {{TOKEN}}", ["TOKEN"], "one"),
            ("{{A_TOKEN}} and {{B_TOKEN}}", ["A_TOKEN", "B_TOKEN"], "two"),
            ("{{TOKEN}} {{TOKEN}}", ["TOKEN"], "repeated collapses"),
            ("{{TOKEN|json}}", ["TOKEN"], "filters are ignored"),
            ("{{ TOKEN }}", ["TOKEN"], "surrounding whitespace, which the engine also trims"),
            ("{{result|llm:\"use {{TOKEN}}\"}}", [], "nested in a filter argument is literal text, so no value is ever resolved and there is nothing to refuse"),
            ("{{TOKEN", [], "unterminated"),
            ("{TOKEN}", [], "single braces"),
            ("{{}}", [], "empty placeholder"),
            ("{{lower}} {{UPPER}}", ["UPPER"], "mixed"),
        ]

        for (template, expected, why) in cases {
            XCTAssertEqual(SecretReference.names(in: template), expected, "\(template): \(why)")
        }
    }

    func testReferencesAnySecret() {
        XCTAssertTrue(SecretReference.referencesAnySecret("curl -H \"Bearer {{TOKEN}}\""))
        XCTAssertFalse(SecretReference.referencesAnySecret("echo {{result}}"))
    }

    // MARK: - Agreement with the engine's own parser

    /// `SecretReference.names(in:)` is a second, deliberately independent scanner:
    /// it lives in the shared package so the validator can use it, while the
    /// engine's parser stays in the app. Two parsers is a drift risk, and the
    /// dangerous direction is the validator saying "no secret here" while the
    /// engine happily resolves one. This pins them together on a corpus.
    func testTheScannerAgreesWithTheEngineOnWhatIsASecret() async throws {
        let corpus = [
            "echo {{result}}",
            "echo {{TOKEN}}",
            "curl -H \"Authorization: Bearer {{NOTION_API_TOKEN}}\" https://api.notion.com",
            "{{A}} {{B_2}} {{result|shell}}",
            "{{TOKEN|json}}",
            "{{ TOKEN }}",
            "plain text, no placeholders",
        ]

        for template in corpus {
            let scanned = SecretReference.names(in: template)

            // What the engine does with the same template: if the scanner found
            // nothing, rendering with no access must succeed, and if it found
            // something, rendering must be refused.
            do {
                _ = try await TemplateEngine.render(template, vars: ["result": "x"], context: .raw, secrets: nil)
                XCTAssertTrue(scanned.isEmpty, "the engine rendered \(template) but the scanner claimed secrets \(scanned)")
            } catch TemplateEngine.FilterError.secretNotAllowed(let name) {
                XCTAssertTrue(scanned.contains(name), "the engine refused \(name) in \(template) but the scanner missed it")
            }
        }
    }
}
