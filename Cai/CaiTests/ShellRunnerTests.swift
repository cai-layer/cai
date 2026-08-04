import XCTest
@testable import Cai

/// The single shell path, covering what the three copies it replaced never had
/// a test for.
///
/// The large-output and large-input cases are the point of the extraction: every
/// previous copy read stdout only after `waitUntilExit()`, which deadlocks once
/// a command outfills the ~64KB pipe buffer (CAI-15). Both cases hang forever
/// against the old implementation, so they are the regression guard.
final class ShellRunnerTests: XCTestCase {

    // MARK: - The deadlock these tests exist for

    func testOutputLargerThanThePipeBufferCompletes() async throws {
        let byteCount = 200_000  // comfortably past the ~64KB pipe buffer
        let output = try await ShellRunner.run("yes a | head -c \(byteCount)", stdin: "")

        XCTAssertEqual(output.status, 0)
        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(output.stdout.count, byteCount, "output was truncated, which means it was read after exit rather than drained")
    }

    func testInputLargerThanThePipeBufferCompletes() async throws {
        let input = String(repeating: "x", count: 200_000)
        let output = try await ShellRunner.run("wc -c", stdin: input)

        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(Int(output.trimmedStdout), input.count, "stdin was truncated or the write blocked")
    }

    func testACommandThatExitsWithoutReadingStdinDoesNotKillTheApp() async throws {
        // Writing to a pipe with no reader raises SIGPIPE, which takes the whole
        // process down. This exact case (a nonexistent command, which exits 127
        // without reading) crashed the test host before F_SETNOSIGPIPE, so if
        // this test runs to its assertions at all, the guard is working.
        let output = try await ShellRunner.run("definitely_not_a_real_command_zzz", stdin: "piped value")

        XCTAssertEqual(output.status, 127)
        XCTAssertTrue(output.stderr.contains("not found"))
    }

    func testLargeInputToACommandThatIgnoresItStillFinishes() async throws {
        // The old code wrote stdin synchronously before `run()`, so this blocked
        // the caller forever. Now the write lives in its own task and ends in
        // EPIPE when the command exits without reading, which must surface as a
        // caught error rather than SIGPIPE killing the host process.
        let output = try await ShellRunner.run("echo done", stdin: String(repeating: "x", count: 200_000))

        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.trimmedStdout, "done")
    }

    func testLargeStderrDoesNotBlockEither() async throws {
        let output = try await ShellRunner.run("yes e | head -c 200000 >&2", stdin: "")

        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stderr.count, 200_000)
        XCTAssertEqual(output.stdout, "")
    }

    // MARK: - Streams

    func testStdinReachesTheCommand() async throws {
        let output = try await ShellRunner.run("cat", stdin: "piped value")
        XCTAssertEqual(output.trimmedStdout, "piped value")
    }

    func testStdoutAndStderrStaySeparateByDefault() async throws {
        let output = try await ShellRunner.run("echo out; echo err >&2", stdin: "")

        XCTAssertEqual(output.trimmedStdout, "out")
        XCTAssertEqual(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
    }

    func testMergingPutsStderrOnStdout() async throws {
        let output = try await ShellRunner.run("echo err >&2", stdin: "", mergeStderrIntoStdout: true)

        XCTAssertEqual(output.trimmedStdout, "err", "shell destinations report one combined stream")
        XCTAssertEqual(output.stderr, "", "nothing is read separately when the pipes are shared")
    }

    // MARK: - Exit status

    func testNonZeroExitIsReportedNotThrown() async throws {
        let output = try await ShellRunner.run("exit 3", stdin: "")

        XCTAssertEqual(output.status, 3)
        XCTAssertFalse(output.timedOut)
    }

    func testFailureMessagePrefersStderr() async throws {
        let output = try await ShellRunner.run("echo 'no such thing' >&2; exit 1", stdin: "")
        XCTAssertTrue(output.failureMessage.contains("no such thing"))
    }

    func testFailureMessageFallsBackToTheExitCode() async throws {
        let output = try await ShellRunner.run("exit 42", stdin: "")
        XCTAssertEqual(output.failureMessage, "Command failed with exit code 42")
    }

    // MARK: - Environment

    func testHomebrewPathsArePresent() async throws {
        let output = try await ShellRunner.run("echo $PATH", stdin: "")

        XCTAssertTrue(output.trimmedStdout.contains("/opt/homebrew/bin"), "the chain copy lacked this, so gh and jq failed inside chains")
        XCTAssertTrue(output.trimmedStdout.contains("/usr/local/bin"))
    }

    func testAnExplicitEnvironmentReplacesTheDefault() async throws {
        let output = try await ShellRunner.run(
            "echo $CAI_TEST_VALUE",
            stdin: "",
            environment: ["CAI_TEST_VALUE": "from the environment", "PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(output.trimmedStdout, "from the environment", "the environment is how secrets will reach a command without entering argv")
    }

    // MARK: - Timeout

    func testATimeoutTerminatesTheCommand() async throws {
        let output = try await ShellRunner.run("sleep 30", stdin: "", timeout: 1)

        XCTAssertTrue(output.timedOut)
        XCTAssertNotEqual(output.status, 0)
    }

    func testTheTimeoutMessageAvoidsTheProviderErrorHeuristic() {
        let message = ShellRunner.timeoutError().localizedDescription

        XCTAssertTrue(message.contains("exceeded"))
        XCTAssertFalse(message.lowercased().contains("timed out"), "ResultView matches that phrase and would suggest checking the model provider")
    }
}
