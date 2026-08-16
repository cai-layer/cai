import XCTest
@testable import Cai

/// Locks the invariant that keeps Cai the TCC *responsible process*: action
/// shells must be spawned by a plain parent/child `Process`, never detached.
///
/// If a future change detaches the shell (`startNewSession`, `setsid`, a
/// launchd/`launchctl` re-launch, or a `responsibility_spawnattrs_setdisclaim`
/// disclaim), the kernel reassigns TCC responsibility away from Cai.app and
/// every Calendar/Contacts/Apple-Events grant silently fails with no prompt —
/// the exact failure that motivated the permissions work. That regression
/// wouldn't fail any behavioural test (it only shows up against real system
/// state), so we guard it structurally by scanning the one file that spawns
/// action shells. See `_docs/architecture/PERMISSIONS.md`.
final class ResponsibilityChainGuardTests: XCTestCase {

    /// APIs that would break attribution if they ever appeared in ShellRunner.
    private let forbiddenTokens = [
        "startNewSession",
        "setsid",
        "responsibility_spawnattrs_setdisclaim",
        "posix_spawnattr_setflags",   // detaching flags are set through this
        "launchctl",
        "SMAppService",
    ]

    func testShellRunnerNeverDetachesTheActionShell() throws {
        let source = try shellRunnerSource()
        for token in forbiddenTokens {
            // The word appears in the explanatory comment as a negative ("never
            // startNewSession…"). Strip comment lines before scanning so the
            // guard tests the *code*, not the prose describing it.
            let codeOnly = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(
                codeOnly.contains(token),
                "ShellRunner must not detach the action shell (found \"\(token)\") — this reassigns TCC responsibility and silently denies every permission. See PERMISSIONS.md."
            )
        }
    }

    // MARK: - Source location

    /// Resolves `ShellRunner.swift` relative to this test file. `#filePath` is
    /// the compile-time absolute path, valid on the machine that runs the suite.
    private func shellRunnerSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)                 // …/Cai/CaiTests/ThisFile.swift
        let projectDir = testFile.deletingLastPathComponent()          // …/Cai/CaiTests
            .deletingLastPathComponent()                               // …/Cai
        let shellRunner = projectDir
            .appendingPathComponent("Cai/Services/ShellRunner.swift")
        guard FileManager.default.fileExists(atPath: shellRunner.path) else {
            throw XCTSkip("ShellRunner.swift not found at \(shellRunner.path) — source layout differs in this environment.")
        }
        return try String(contentsOf: shellRunner, encoding: .utf8)
    }
}
