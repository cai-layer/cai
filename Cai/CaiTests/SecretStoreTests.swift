import XCTest
import CaiActionCore
@testable import Cai

/// `SecretStore`, `SecretValue` and `Redactor`.
///
/// The store tests touch the real Keychain, under names prefixed so they cannot
/// collide with anything a developer actually stores, and each one cleans up
/// after itself. That is worth the cost: the Keychain-as-the-list decision rests
/// on enumeration returning names without values, and a mock would pin the mock.
final class SecretStoreTests: XCTestCase {

    private let testName = "ZZ_CAI_TEST_SECRET"
    private let otherName = "ZZ_CAI_TEST_OTHER"

    override func tearDown() {
        SecretStore.delete(testName)
        SecretStore.delete(otherName)
        super.tearDown()
    }

    // MARK: - SecretValue cannot be logged by accident

    func testTheValueDoesNotAppearInAnyStringConversion() {
        let secret = SecretValue("sk-live-should-never-print")

        XCTAssertEqual("\(secret)", "<redacted>", "string interpolation is the common accident")
        XCTAssertEqual(String(describing: secret), "<redacted>")
        XCTAssertEqual(String(reflecting: secret), "<redacted>")
        XCTAssertEqual(secret.description, "<redacted>")
        XCTAssertEqual(secret.debugDescription, "<redacted>")
        XCTAssertFalse("\(secret)".contains("sk-live"))
    }

    func testTheValueIsStillReachableDeliberately() {
        XCTAssertEqual(SecretValue("abc").raw, "abc", "explicit .raw is the only way in, and it greps")
    }

    // MARK: - Store round trip

    func testSaveThenReadThenDelete() {
        XCTAssertEqual(SecretStore.save("first-value", name: testName), .saved)
        XCTAssertEqual(SecretStore.value(for: testName)?.raw, "first-value")

        XCTAssertEqual(SecretStore.save("second-value", name: testName), .replaced, "overwrite is how rotation works")
        XCTAssertEqual(SecretStore.value(for: testName)?.raw, "second-value")

        XCTAssertTrue(SecretStore.delete(testName))
        XCTAssertNil(SecretStore.value(for: testName))
    }

    func testDeletingSomethingAbsentSucceeds() {
        XCTAssertTrue(SecretStore.delete(testName), "idempotent, so a double delete is not an error")
    }

    func testAnInvalidNameIsRejectedBeforeTheKeychain() {
        guard case .invalidName(let message) = SecretStore.save("v", name: "bad name") else {
            return XCTFail("an invalid name reached the Keychain")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(SecretStore.value(for: "bad name"))
    }

    func testAnEmptyValueIsRefused() {
        // An empty value stores fine at the Keychain layer but hands a blank
        // credential to the command at run time, failing far away with the
        // wrong error. Refuse it at the source — both the form and a `FOO=`
        // shell-import entry stop here rather than persisting a blank secret.
        guard case .invalidName = SecretStore.save("", name: testName) else {
            return XCTFail("empty value should be refused")
        }
        // Whitespace-only collapses to empty after the trim and is refused too.
        guard case .invalidName = SecretStore.save("   \n", name: testName) else {
            return XCTFail("whitespace-only value should be refused")
        }
        XCTAssertFalse(SecretStore.exists(testName), "nothing was persisted")
    }

    func testAPastedTrailingNewlineIsTrimmedAtSave() {
        // pbcopy and terminal copies routinely append one. Stored verbatim it
        // breaks auth and defeats redaction (echoed output has no newline, so
        // the stored raw never matches).
        SecretStore.save("sk-live-abc\n", name: testName)
        XCTAssertEqual(SecretStore.value(for: testName)?.raw, "sk-live-abc")

        SecretStore.save("  sk-live-abc  \n", name: testName)
        XCTAssertEqual(SecretStore.value(for: testName)?.raw, "sk-live-abc", "ends trimmed")

        SecretStore.save("line1\nline2", name: testName)
        XCTAssertEqual(SecretStore.value(for: testName)?.raw, "line1\nline2", "interior newlines stay, PEM-style material is legitimate")
    }

    // MARK: - Lookup preserves the failure mode

    func testLookupDistinguishesMissingFromFound() {
        XCTAssertEqual(SecretStore.lookup(testName), .missing)
        SecretStore.save("v", name: testName)
        XCTAssertEqual(SecretStore.lookup(testName), .found(SecretValue("v")))
    }

    func testResolveThrowsUnknownSecretForAMissingName() {
        do {
            _ = try SecretStore.resolve([testName])
            XCTFail("resolved a missing secret")
        } catch TemplateEngine.FilterError.unknownSecret(let name) {
            XCTAssertEqual(name, testName)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Enumeration

    func testTheListReportsNamesAndDatesWithoutValues() throws {
        SecretStore.save("value-a", name: testName)

        let entry = try XCTUnwrap(SecretStore.list().first { $0.name == testName })
        XCTAssertNotNil(entry.created, "the list shows an Added date, which the Keychain supplies for free")
        XCTAssertFalse("\(entry)".contains("value-a"), "no descriptor may carry the value")
    }

    func testTheListIgnoresTheModelAPIKeys() {
        SecretStore.save("value-a", name: testName)

        let names = SecretStore.list().map(\.name)
        XCTAssertTrue(names.contains(testName))
        for foreign in ["cai_apiKey", "cai_anthropicApiKey", "cai_openRouterApiKey"] {
            XCTAssertFalse(names.contains(foreign), "\(foreign) shares the service but is not a secret")
        }
    }

    func testTheListIsSortedByName() {
        SecretStore.save("v", name: otherName)   // ZZ_CAI_TEST_OTHER
        SecretStore.save("v", name: testName)    // ZZ_CAI_TEST_SECRET

        let ours = SecretStore.list().map(\.name).filter { $0.hasPrefix("ZZ_CAI_TEST") }
        XCTAssertEqual(ours, [otherName, testName])
    }

    func testExists() {
        XCTAssertFalse(SecretStore.exists(testName))
        SecretStore.save("v", name: testName)
        XCTAssertTrue(SecretStore.exists(testName))
    }

    func testEnumerateReportsItemsAndListMatches() {
        // The unavailable branch can't be forced against a live keychain; what
        // can be pinned is that the healthy path reports .items and that the
        // convenience list() is exactly those items.
        SecretStore.save("v", name: testName)
        guard case .items(let items) = SecretStore.enumerate() else {
            return XCTFail("a healthy keychain reported unavailable")
        }
        XCTAssertEqual(items, SecretStore.list())
        XCTAssertTrue(items.contains { $0.name == testName })
    }

    // MARK: - Resolution for a shell command

    func testATemplateWithoutSecretsChangesNothing() throws {
        let prepared = try SecretStore.prepareForShell(template: "echo {{result}} {{API_KEY}}")

        XCTAssertTrue(prepared.isEmpty)
        XCTAssertNil(prepared.access, "no access means the engine keeps refusing")
        XCTAssertNil(prepared.environment, "the runner keeps its default environment")
    }

    func testPreparationPutsTheValueInTheEnvironment() throws {
        SecretStore.save("sk-live-xyz", name: testName)

        let prepared = try SecretStore.prepareForShell(template: "curl -H \"Bearer {{secrets.\(testName)}}\"")

        XCTAssertEqual(prepared.environment?["CAI_SECRET_\(testName)"], "sk-live-xyz")
        XCTAssertNotNil(prepared.environment?["PATH"], "the Homebrew PATH must survive")
        XCTAssertEqual(prepared.values.count, 1)
    }

    func testPreparationFailsOnAMissingSecret() {
        do {
            _ = try SecretStore.prepareForShell(template: "echo {{secrets.ZZ_CAI_TEST_ABSENT}}")
            XCTFail("a missing secret was resolved to nothing")
        } catch TemplateEngine.FilterError.unknownSecret(let name) {
            XCTAssertEqual(name, "ZZ_CAI_TEST_ABSENT")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPreparationFollowsTheEngineNotTheScanner() throws {
        // The quoted-`}}` template where the two parsers disagree: the engine
        // treats {{secrets.…}} inside the llm arg as literal text, so no
        // environment may be built for it, even though the scanner over-reports.
        SecretStore.save("v", name: testName)

        let template = "{{result|llm:\"see }} {{secrets.\(testName)}} docs\"}}"
        let prepared = try SecretStore.prepareForShell(template: template)

        XCTAssertTrue(prepared.isEmpty, "a secret was handed to a command that never references it")
    }

    // MARK: - Redaction

    func testRedactionReplacesEveryOccurrence() {
        let secret = SecretValue("sk-live-abcdef")
        let text = "failed with sk-live-abcdef and again sk-live-abcdef"

        let redacted = Redactor.redact(text, using: [secret])

        XCTAssertFalse(redacted.contains("sk-live-abcdef"))
        XCTAssertEqual(redacted, "failed with <redacted> and again <redacted>")
    }

    func testTheLongerSecretIsRedactedFirst() {
        // A short secret that is a prefix of a longer one must not leave the
        // longer one's tail exposed.
        let short = SecretValue("sk-live")
        let long = SecretValue("sk-live-full-token")

        let redacted = Redactor.redact("here is sk-live-full-token", using: [short, long])

        XCTAssertFalse(redacted.contains("full-token"), "got: \(redacted)")
    }

    func testVeryShortSecretsAreNotRedacted() {
        // Redacting "ab" would blank out ordinary words and hide the error the
        // user needs to read, while protecting nothing worth protecting.
        let redacted = Redactor.redact("a table of absolute values", using: [SecretValue("ab")])
        XCTAssertEqual(redacted, "a table of absolute values")
    }

    func testRedactionWithNothingToRedact() {
        XCTAssertEqual(Redactor.redact("plain output", using: []), "plain output")
        XCTAssertEqual(Redactor.redact("", using: [SecretValue("sk-live-abcdef")]), "")
    }
}
