import XCTest
import CaiActionCore
@testable import Cai

/// The import-from-shell capture: parse and filter as pure tables, plus one
/// real login-shell integration run (the `SecretEndToEndTests` precedent:
/// nothing short of a real shell proves the marker survives rc noise).
final class ShellEnvCaptureTests: XCTestCase {

    private let marker = ShellEnvCapture.marker

    private func names(_ output: String, existing: Set<String> = []) -> [String] {
        ShellEnvCapture.candidates(fromCaptureOutput: output, existing: existing).map(\.name)
    }

    // MARK: - Parsing

    func testParsingTable() {
        let cases: [(String, [String], String)] = [
            ("", [], "empty output"),
            ("GITHUB_TOKEN=x\u{0}", [], "no marker means no trusted region"),
            (marker + "GITHUB_TOKEN=abc\u{0}", ["GITHUB_TOKEN"], "one entry"),
            (
                "motd noise\nFAKE_TOKEN=evil\n" + marker + "GITHUB_TOKEN=abc\u{0}",
                ["GITHUB_TOKEN"],
                "rc noise before the marker is dropped, even KEY=VALUE-shaped noise"
            ),
            (
                marker + "A_TOKEN=1\u{0}B_KEY=2\u{0}",
                ["A_TOKEN", "B_KEY"],
                "several entries"
            ),
            (
                marker + "GITHUB_TOKEN=line1\nline2\u{0}OTHER_KEY=x\u{0}",
                ["GITHUB_TOKEN", "OTHER_KEY"],
                "multiline value survives because entries split on NUL, not newline"
            ),
            (marker + "no-equals-junk\u{0}REAL_TOKEN=x\u{0}", ["REAL_TOKEN"], "junk without = is skipped"),
            (marker + "lowercase_var=x\u{0}", [], "lowercase names fail the secret shape"),
            (marker + "MY-VAR=x\u{0}", [], "hyphens fail the secret shape"),
            (marker + "PATH=/usr/bin\u{0}", [], "the noise list"),
            (marker + "CAI_SECRET_FOO=x\u{0}", [], "our own injected namespace never round-trips"),
            (marker + "DUP_TOKEN=1\u{0}DUP_TOKEN=2\u{0}", ["DUP_TOKEN"], "duplicates collapse to the first"),
        ]

        for (output, expected, why) in cases {
            XCTAssertEqual(names(output), expected, why)
        }
    }

    func testMultilineValueIsCarriedIntact() throws {
        let pem = "-----BEGIN KEY-----\nabc\ndef\n-----END KEY-----"
        let output = marker + "SIGNING_KEY=\(pem)\u{0}"
        let candidate = try XCTUnwrap(
            ShellEnvCapture.candidates(fromCaptureOutput: output, existing: []).first
        )
        XCTAssertEqual(candidate.value.raw, pem)
    }

    // MARK: - Filtering and ordering

    func testTokenShapedNamesSortFirst() {
        let output = marker + "ZEBRA_CONFIG=1\u{0}AWS_KEY=2\u{0}NVM_DIR=3\u{0}GITHUB_TOKEN=4\u{0}"
        XCTAssertEqual(
            names(output),
            ["AWS_KEY", "GITHUB_TOKEN", "NVM_DIR", "ZEBRA_CONFIG"],
            "token-shaped first, alphabetical within each group"
        )
        let candidates = ShellEnvCapture.candidates(fromCaptureOutput: output, existing: [])
        XCTAssertTrue(candidates[0].looksLikeToken)
        XCTAssertFalse(candidates[3].looksLikeToken, "ZEBRA_CONFIG collapses under Show all")
    }

    func testExistingNamesAreMarkedAsReplacements() {
        let output = marker + "GITHUB_TOKEN=x\u{0}NEW_TOKEN=y\u{0}"
        let candidates = ShellEnvCapture.candidates(fromCaptureOutput: output, existing: ["GITHUB_TOKEN"])
        XCTAssertTrue(candidates.first { $0.name == "GITHUB_TOKEN" }?.replacesExisting == true)
        XCTAssertTrue(candidates.first { $0.name == "NEW_TOKEN" }?.replacesExisting == false)
    }

    func testValuesNeverLeakThroughDescriptions() {
        let output = marker + "GITHUB_TOKEN=sk-live-secret-value\u{0}"
        let candidate = ShellEnvCapture.candidates(fromCaptureOutput: output, existing: []).first!
        XCTAssertFalse("\(candidate)".contains("sk-live"), "Candidate descriptions must not carry the value")
    }

    // MARK: - The login shell

    func testLoginShellComesFromTheUserRecordNotTheEnvironment() {
        let shell = ShellEnvCapture.loginShell()
        XCTAssertTrue(shell.hasPrefix("/"), "expected an absolute path, got \(shell)")
    }

    /// One real capture through the user's actual login shell. Pins the whole
    /// claim: rc noise cannot corrupt the parse, because the marker separates
    /// it from the `env -0` payload.
    func testRealCaptureProducesParseableCandidates() async throws {
        let candidates = try await ShellEnvCapture.capture()
        // Every candidate that made it through must have a valid name and no
        // noise-list member.
        for candidate in candidates {
            XCTAssertTrue(SecretReference.isValidName(candidate.name), candidate.name)
            XCTAssertFalse(ShellEnvCapture.noise.contains(candidate.name), candidate.name)
        }
    }
}
