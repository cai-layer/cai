import Foundation

/// The one place Cai runs a shell command.
///
/// This existed three times over (shell shortcut, chain shell step, shell
/// destination) and the copies had already drifted: the chain step never set
/// the Homebrew PATH, so a `gh` or `jq` command that worked as a standalone
/// action failed inside a chain with "command not found". Extracting it is what
/// keeps the next change from having to be made three times and remembered
/// twice.
///
/// **Output is drained while the process runs.** All three copies read stdout
/// only after `waitUntilExit()`, which deadlocks as soon as a command writes
/// more than the pipe buffer holds (~64KB): the command blocks on a full pipe,
/// we block waiting for it to exit. That is CAI-15, and it is fixed here rather
/// than in three places. Same for stdin, which is written from its own task
/// because a large input blocks until something reads the other end.
enum ShellRunner {

    /// 60 seconds. Comfortable buffer for a `|llm` filter cold start (~5-15s)
    /// plus the command itself. Per-action timeouts are later work.
    static let defaultTimeout: TimeInterval = 60

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
        /// The process was killed by a signal, which in practice means our
        /// timeout fired. Kept as the same heuristic the three copies used.
        let timedOut: Bool

        /// stdout with surrounding whitespace removed, which is what every
        /// caller that propagates output actually wants.
        var trimmedStdout: String {
            stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// stderr if the command wrote any, otherwise a generic exit-code
        /// message. The shape all three copies built by hand.
        var failureMessage: String {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Command failed with exit code \(status)" : stderr
        }
    }

    /// Runs `command` through `/bin/zsh -c`.
    ///
    /// - Parameters:
    ///   - command: the fully resolved command line. Templates must already be
    ///     rendered; this function does no substitution and no escaping.
    ///   - stdin: piped to the command, so a user can consume it `cat`-style.
    ///   - environment: defaults to `OutputDestinationService.shellEnvironment()`,
    ///     which prepends the Homebrew paths that non-interactive zsh lacks.
    ///   - mergeStderrIntoStdout: shell destinations report one combined stream
    ///     on failure and relied on a single pipe to interleave it. Preserved so
    ///     the extraction changes no output.
    ///   - timeout: seconds before the process is terminated.
    static func run(
        _ command: String,
        stdin: String,
        environment: [String: String]? = nil,
        mergeStderrIntoStdout: Bool = false,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = environment ?? OutputDestinationService.shellEnvironment()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = mergeStderrIntoStdout ? outputPipe : Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Writing to a pipe whose reader is gone raises SIGPIPE, which kills the
        // whole app rather than failing the command. That became reachable the
        // moment stdin moved after `run()`: a command that exits without reading
        // it, a mistyped command name for instance, closes the read end first.
        // F_SETNOSIGPIPE turns the signal into an EPIPE we can swallow, which is
        // the right outcome because the command was never listening.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        try process.run()

        // Write stdin and read both streams concurrently with the process, or a
        // command whose input or output exceeds the pipe buffer never finishes:
        // it blocks on a full pipe while we wait for it to exit.
        //
        // All four of these block their thread, so they go to a dedicated
        // concurrent queue rather than `Task.detached`. Detached tasks run on the
        // cooperative pool, which has roughly one thread per core, and four
        // blocking calls per invocation exhaust it: tasks stop being scheduled
        // and the runner hangs. Only the timeout stays a Task, because
        // `Task.sleep` suspends instead of blocking.
        async let stdoutData = readToEnd(outputPipe.fileHandleForReading)
        async let stderrData = mergeStderrIntoStdout ? Data() : readToEnd(errorPipe.fileHandleForReading)
        async let stdinWritten: Void = write(stdin, to: inputPipe.fileHandleForWriting)

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            process.terminate()
        }
        await waitForExit(process)
        timeoutTask.cancel()

        await stdinWritten
        let outData = await stdoutData
        let errData = await stderrData

        return Output(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            timedOut: process.terminationReason == .uncaughtSignal
        )
    }

    // MARK: - Blocking I/O, off the cooperative pool

    /// Serves the reads, the write, and `waitUntilExit`. Concurrent, because one
    /// invocation needs three of them at once and they all block.
    private static let ioQueue = DispatchQueue(
        label: "com.soyasis.cai.shell",
        attributes: .concurrent
    )

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private static func write(_ text: String, to handle: FileHandle) async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                if let data = text.data(using: .utf8), !data.isEmpty {
                    // Throws EPIPE when the command exited without reading. That
                    // is not an error worth surfacing: it was not listening.
                    try? handle.write(contentsOf: data)
                }
                try? handle.close()
                continuation.resume()
            }
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    /// The error every caller that surfaces a timeout to the user throws.
    ///
    /// Phrasing avoids "timed out" deliberately: `ResultView`'s provider-error
    /// heuristic matches that phrase and would show a misleading
    /// "Check Settings → Model Provider" hint.
    static func timeoutError(seconds: TimeInterval = defaultTimeout) -> NSError {
        NSError(domain: "Cai", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Shell command exceeded \(Int(seconds))s and was stopped"
        ])
    }
}
