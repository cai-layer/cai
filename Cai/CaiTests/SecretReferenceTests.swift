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
            ("notion_token", false, "lowercase"),
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

    func testRejectionsExplainThemselves() {
        XCTAssertNil(SecretReference.nameRejection("NOTION_API_TOKEN"))
        XCTAssertEqual(SecretReference.nameRejection(""), "Give the secret a name.")
        XCTAssertTrue(SecretReference.nameRejection("a")?.contains("two characters") == true)
        XCTAssertTrue(SecretReference.nameRejection("token")?.contains("upper-case letter") == true)
        XCTAssertTrue(SecretReference.nameRejection("MY-TOKEN")?.contains("underscores") == true)
        XCTAssertTrue(SecretReference.nameRejection(String(repeating: "A", count: 99))?.contains("64") == true)
    }

    // MARK: - The namespace

    func testNameFromReference() {
        let cases: [(String, String?, String)] = [
            ("secrets.NOTION_API_TOKEN", "NOTION_API_TOKEN", "the ordinary case"),
            ("secrets.AB", "AB", "shortest valid name"),
            ("result", nil, "no namespace"),
            ("NOTION_API_TOKEN", nil, "bare uppercase is an ordinary variable, the pre-namespace syntax must not resolve"),
            ("secrets.notion_token", nil, "namespace claimed but the name is broken"),
            ("secrets.", nil, "namespace with nothing after it"),
            ("secrets", nil, "the namespace word alone is an ordinary variable"),
            ("Secrets.TOKEN", nil, "namespace is case-sensitive"),
        ]
        for (variable, expected, why) in cases {
            XCTAssertEqual(SecretReference.name(fromReference: variable), expected, "\(variable): \(why)")
        }
    }

    func testClaimsNamespaceSeparatesWrongFromAbsent() {
        // "written wrong" (engine throws loud) vs "not a secret" (ordinary var).
        XCTAssertTrue(SecretReference.claimsNamespace("secrets.bad-name"))
        XCTAssertTrue(SecretReference.claimsNamespace("secrets."))
        XCTAssertFalse(SecretReference.claimsNamespace("API_KEY"))
        XCTAssertFalse(SecretReference.claimsNamespace("secrets"))
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
            ("echo {{TOKEN}}", [], "bare uppercase is an ordinary variable now"),
            ("echo {{secrets.TOKEN}}", ["TOKEN"], "one"),
            ("{{secrets.A_TOKEN}} and {{secrets.B_TOKEN}}", ["A_TOKEN", "B_TOKEN"], "two"),
            ("{{secrets.TOKEN}} {{secrets.TOKEN}}", ["TOKEN"], "repeated collapses"),
            ("{{secrets.TOKEN|json}}", ["TOKEN"], "filters are ignored"),
            ("{{ secrets.TOKEN }}", ["TOKEN"], "surrounding whitespace, which the engine also trims"),
            ("{{secrets.TOKEN", [], "unterminated"),
            ("{secrets.TOKEN}", [], "single braces"),
            ("{{}}", [], "empty placeholder"),
            ("{{secrets.bad-name}}", [], "broken name; the engine refuses it loudly instead"),
        ]

        for (template, expected, why) in cases {
            XCTAssertEqual(SecretReference.names(in: template), expected, "\(template): \(why)")
        }
    }

    func testReferencesAnySecret() {
        XCTAssertTrue(SecretReference.referencesAnySecret("curl -H \"Bearer {{secrets.TOKEN}}\""))
        XCTAssertFalse(SecretReference.referencesAnySecret("echo {{result}} {{TOKEN}}"))
    }

    // MARK: - Agreement with the engine's own parser

    /// The package scanner is quote-blind and the engine's parser is not, so on
    /// templates with `}}` inside quoted filter args they genuinely disagree.
    /// The contract that matters is the direction: the scanner may over-report
    /// (a proposal looks slightly scarier than it is) but must never
    /// under-report (a credential hidden from the approval sheet). Execution
    /// never trusts the scanner — `prepareForShell` uses
    /// `TemplateEngine.secretNames` — so over-reporting cannot put a secret in
    /// any environment.
    func testTheScannerNeverUnderReportsAgainstTheEngine() {
        let corpus = [
            "echo {{result}}",
            "echo {{secrets.TOKEN}}",
            "curl -H \"Authorization: Bearer {{secrets.NOTION_API_TOKEN}}\" https://api.notion.com",
            "{{secrets.A}} {{secrets.B_2}} {{result|shell}}",
            "{{secrets.TOKEN|json}}",
            "{{ secrets.TOKEN }}",
            "{{TOKEN}} {{API_KEY}}",
            "plain text, no placeholders",
            // The divergence class: `}}` inside a quoted filter arg. The engine
            // sees one placeholder and no secret; the scanner desyncs and
            // over-reports AWS_KEY. That direction is allowed.
            "{{result|llm:\"see }} {{secrets.AWS_KEY}} docs\"}}",
        ]

        for template in corpus {
            let scanned = SecretReference.names(in: template)
            let engine = TemplateEngine.secretNames(in: template)
            XCTAssertTrue(
                engine.isSubset(of: scanned),
                "the engine resolves \(engine) in \(template) but the scanner only saw \(scanned)"
            )
        }
    }

    func testEngineNamesFollowTheParserNotTheScanner() {
        // The template where the two disagree: prepareForShell must side with
        // the engine, or a secret lands in the environment of a command that
        // never references it.
        let template = "{{result|llm:\"see }} {{secrets.AWS_KEY}} docs\"}}"
        XCTAssertEqual(TemplateEngine.secretNames(in: template), [])
        XCTAssertEqual(SecretReference.names(in: template), ["AWS_KEY"], "over-reporting is the accepted direction")
    }

    /// The engine's own extraction matches what rendering refuses: if
    /// `secretNames` is empty, rendering with no access succeeds; if not, it is
    /// refused with one of the names.
    func testEngineNamesAgreeWithRendering() async throws {
        let corpus = [
            "echo {{result}}",
            "echo {{secrets.TOKEN}}",
            "curl -H \"Authorization: Bearer {{secrets.NOTION_API_TOKEN}}\" https://api.notion.com",
            "{{ secrets.TOKEN }}",
            "{{TOKEN}} {{API_KEY}}",
            "plain text, no placeholders",
        ]

        for template in corpus {
            let names = TemplateEngine.secretNames(in: template)
            do {
                _ = try await TemplateEngine.render(template, vars: ["result": "x"], context: .raw, secrets: nil)
                XCTAssertTrue(names.isEmpty, "the engine rendered \(template) but claimed secrets \(names)")
            } catch TemplateEngine.FilterError.secretNotAllowed(let name) {
                XCTAssertTrue(names.contains(name), "the engine refused \(name) in \(template) but secretNames missed it")
            }
        }
    }
}
