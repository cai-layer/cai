import XCTest
import CaiActionCore
@testable import Cai

/// A real secret, through the real store, into a real command.
///
/// The unit tests pin each layer's decision in isolation; this is the one place
/// they meet, and it pins the claim the feature actually makes to the user: the
/// command can use the token, and the token is not in the command line. It is
/// deliberately the only test here that spawns a real subprocess. Redaction and
/// the sink policy are covered without one; this exists because nothing short of
/// a real `zsh` proves the environment reference resolves to the value.
final class SecretEndToEndTests: XCTestCase {

    private let secretName = "ZZ_CAI_E2E_TOKEN"
    private let value = "sk-live-e2e-9f8e7d6c"

    override func setUp() {
        super.setUp()
        SecretStore.save(value, name: secretName)
    }

    override func tearDown() {
        SecretStore.delete(secretName)
        super.tearDown()
    }

    func testACommandCanUseTheSecretWithoutItEnteringTheCommandLine() async throws {
        // Unquoted in the template: the engine supplies the quotes around the
        // environment reference itself.
        let template = "printf '%s' {{secrets.\(secretName)}}"

        let prepared = try SecretStore.prepareForShell(template: template)
        let rendered = try await TemplateEngine.render(
            template,
            vars: ["result": ""],
            context: .shell,
            secrets: prepared.access
        )

        // The rendered command is what would show up in `ps`.
        XCTAssertFalse(rendered.contains(value), "the value entered argv: \(rendered)")
        XCTAssertTrue(rendered.contains("$CAI_SECRET_\(secretName)"))

        let output = try await ShellRunner.run(rendered, stdin: "", environment: prepared.environment)

        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.trimmedStdout, value, "the command could not read the secret it was given")
    }

    func testAPromptStepRefusesTheSameSecret() async {
        // The sink that matters. Same store, same name, same engine.
        do {
            _ = try await TemplateEngine.render(
                "Summarize this using {{secrets.\(secretName)}}",
                vars: ["result": "text"],
                context: .raw,
                secrets: nil
            )
            XCTFail("a prompt resolved a secret")
        } catch TemplateEngine.FilterError.secretNotAllowed(let refused) {
            XCTAssertEqual(refused, secretName)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTheEnvironmentCarriesOnlyTheSecretsTheTemplateAsksFor() throws {
        SecretStore.save("other-value", name: "ZZ_CAI_E2E_OTHER")
        defer { SecretStore.delete("ZZ_CAI_E2E_OTHER") }

        let prepared = try SecretStore.prepareForShell(template: "echo {{secrets.\(secretName)}}")

        XCTAssertNotNil(prepared.environment?["CAI_SECRET_\(secretName)"])
        XCTAssertNil(
            prepared.environment?["CAI_SECRET_ZZ_CAI_E2E_OTHER"],
            "a command must not be handed credentials it never referenced"
        )
    }
}
