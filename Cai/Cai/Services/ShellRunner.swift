import Foundation
import os

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
/// than in three places. Same for stdin, which is written concurrently because
/// a large input blocks until something reads the other end.
///
/// **`run` always returns.** Three things used to be able to park it forever:
/// a command that traps SIGTERM (the timeout's terminate did nothing), a
/// pipeline whose children outlive zsh after a timeout (they hold the pipe
/// write ends, so the drain never sees EOF), and a command that backgrounds a
/// child and exits (same, on the success path). So the timeout escalates to
/// SIGKILL, and once the process has exited the drains get a short deadline:
/// anything the command wrote is already in the pipe buffer and arrives
/// instantly, so only a live orphan can still be holding the pipe open, and we
/// return what was collected rather than wait on a process we don't own.
/// All pipe I/O goes through `DispatchIO`, which can be torn down at that
/// deadline; blocking reads on a queue would park their threads forever in
/// exactly these cases.
///
/// **Exit is signalled, not polled.** `waitUntilExit()` blocks its thread on a
/// run loop and deadlocks when called off the main thread under load (a worker
/// thread parks forever for a command that already exited). Exit comes from
/// `terminationHandler` through `ProcessExitSignal` instead, which parks no
/// thread. This is what let the suite hang after a few hundred cumulative runs.
enum ShellRunner {

    /// 60 seconds. Comfortable buffer for a `|llm` filter cold start (~5-15s)
    /// plus the command itself. Per-action timeouts are later work.
    static let defaultTimeout: TimeInterval = 60

    /// Per-stream cap, 10 MB. The old copies had an accidental ceiling: past
    /// ~64KB they deadlocked and the timeout killed the command. Draining
    /// properly removes that dam, so the cap is what keeps `cat hugefile` from
    /// ballooning memory and freezing ResultView. Same principle as
    /// `ClipboardHistory.maxTextLength`, sized for command output.
    static let maxOutputBytes = 10 * 1024 * 1024

    /// Appended to a stream that hit `maxOutputBytes`. The rest was drained and
    /// discarded so the command still ran to completion.
    static let truncationMarker = "\n[output truncated at 10 MB]"

    /// How long after SIGTERM before SIGKILL. SIGTERM is trappable; a command
    /// that ignores it would otherwise never terminate and the exit signal
    /// would never fire.
    private static let killGrace: TimeInterval = 2

    /// How long after process exit the drains may wait for EOF. Buffered data
    /// arrives in microseconds; the deadline only fires when a surviving child
    /// still holds a pipe end, and waiting on those means hanging forever.
    private static let drainDeadline: TimeInterval = 1

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
        /// Our timeout fired for this command. Set by the timeout itself, not
        /// inferred from the termination reason: a command that segfaults dies
        /// by signal too and used to be misreported as "exceeded 60s".
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
        timeout: TimeInterval = defaultTimeout,
        executable: String = "/bin/zsh",
        flags: String = "-c"
    ) async throws -> Output {
        // `executable`/`flags` exist for ShellEnvCapture, which runs the user's
        // own login shell (`$SHELL -ilc …`). Every other caller wants the
        // defaults; a second Process wrapper would re-meet the SIGPIPE,
        // pool-starvation and waitUntilExit traps documented below.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [flags, command]
        process.environment = environment ?? OutputDestinationService.shellEnvironment()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = mergeStderrIntoStdout ? outputPipe : Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Writing to a pipe whose reader is gone raises SIGPIPE, which kills the
        // whole app rather than failing the command: a command that exits
        // without reading stdin, a mistyped command name for instance, closes
        // the read end first. F_SETNOSIGPIPE turns the signal into an EPIPE the
        // writer can swallow, which is the right outcome because the command was
        // never listening.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // Signal exit through `terminationHandler`, not `waitUntilExit()`.
        // `waitUntilExit` blocks its thread by running a run loop and depends on
        // Foundation delivering the child's termination there, which deadlocks
        // when it is called off the main thread: under load a worker thread
        // parks in `waitUntilExit` forever for a command that already exited.
        // `terminationHandler` fires on a Foundation-internal queue with no
        // parked thread and no run-loop dependency. Set before `run()` so the
        // handler cannot miss a process that exits immediately.
        let exit = ProcessExitSignal()
        process.terminationHandler = { _ in exit.fire() }

        try process.run()

        let stdoutReader = PipeReader(outputPipe.fileHandleForReading, cap: maxOutputBytes)
        let stderrReader = mergeStderrIntoStdout ? nil : PipeReader(errorPipe.fileHandleForReading, cap: maxOutputBytes)
        let stdinWriter = PipeWriter(inputPipe.fileHandleForWriting, data: stdin.data(using: .utf8) ?? Data())

        let timedOutFlag = OSAllocatedUnfairLock(initialState: false)
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            timedOutFlag.withLock { $0 = true }
            process.terminate()
            try await Task.sleep(nanoseconds: UInt64(killGrace * 1_000_000_000))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        await exit.wait()
        timeoutTask.cancel()
        let timedOut = timedOutFlag.withLock { $0 }

        // Drain deadline: normally EOF is already there and this costs nothing;
        // a surviving child holding a pipe end is the only thing that can make
        // it fire, and that child may never exit.
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(drainDeadline * 1_000_000_000))
            stdoutReader.stop()
            stderrReader?.stop()
            stdinWriter.stop()
        }
        await stdoutReader.waitUntilEOF()
        await stderrReader?.waitUntilEOF()
        await stdinWriter.waitUntilDone()
        deadline.cancel()

        let (outData, outTruncated) = stdoutReader.result()
        let (errData, errTruncated) = stderrReader?.result() ?? (Data(), false)

        // Lossy decode: a single invalid byte used to nil the whole string, so
        // Latin-1 error text or binary output became "" with no trace.
        var stdout = String(decoding: outData, as: UTF8.self)
        if outTruncated { stdout += truncationMarker }
        var stderr = String(decoding: errData, as: UTF8.self)
        if errTruncated { stderr += truncationMarker }

        return Output(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
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

// MARK: - Process exit

/// Bridges `Process.terminationHandler` to one `await`.
///
/// The handler is registered before `run()` and fires exactly once when the
/// process exits (including after our SIGTERM or SIGKILL). `wait()` returns
/// immediately if exit already happened, otherwise parks a continuation for the
/// handler to resume. The lock makes the fire/wait race safe in both orders and
/// guarantees a single resume.
private final class ProcessExitSignal: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var exited = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    func fire() {
        let waiter = lock.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.exited else { return nil }
            state.exited = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyExited = lock.withLock { state -> Bool in
                if state.exited { return true }
                state.waiter = continuation
                return false
            }
            if alreadyExited { continuation.resume() }
        }
    }
}

// MARK: - Pipe I/O

/// Accumulates one pipe's output via `DispatchIO`, up to a cap (the rest is
/// drained and discarded so the command never blocks on a full pipe). No thread
/// is parked while waiting, so `stop()` can always tear the channel down and
/// hand back whatever arrived.
private final class PipeReader {
    private let queue = DispatchQueue(label: "com.soyasis.cai.shell.read")
    private let io: DispatchIO
    private var data = Data()
    private var truncated = false
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ handle: FileHandle, cap: Int) {
        // The cleanup handler owns closing the fd; capturing the handle keeps
        // the descriptor alive for as long as the channel needs it.
        io = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            try? handle.close()
        }
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: Int.max, queue: queue) { [self] done, chunk, _ in
            if let chunk, !chunk.isEmpty {
                if data.count < cap {
                    let room = cap - data.count
                    if chunk.count <= room {
                        data.append(contentsOf: chunk)
                    } else {
                        data.append(contentsOf: chunk.prefix(room))
                        truncated = true
                    }
                } else {
                    truncated = true
                }
            }
            if done { finish() }
        }
    }

    /// Resolves at EOF, on a read error, or when `stop()` tears the channel down.
    func waitUntilEOF() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if finished { continuation.resume() } else { waiter = continuation }
            }
        }
    }

    /// Cancels the outstanding read. The handler fires once more with `done`,
    /// which resolves the waiter with whatever was collected.
    func stop() {
        queue.async { [self] in
            guard !finished else { return }
            io.close(flags: .stop)
        }
    }

    func result() -> (data: Data, truncated: Bool) {
        queue.sync { (data, truncated) }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        io.close()
        waiter?.resume()
        waiter = nil
    }
}

/// Writes stdin via `DispatchIO` and closes the write end when done, so the
/// command sees EOF. A command that exits without reading turns the write into
/// EPIPE (thanks to F_SETNOSIGPIPE), which ends the write; that is not an error
/// worth surfacing, the command was not listening.
private final class PipeWriter {
    private let queue = DispatchQueue(label: "com.soyasis.cai.shell.write")
    private var io: DispatchIO?
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ handle: FileHandle, data: Data) {
        guard !data.isEmpty else {
            try? handle.close()
            finished = true
            return
        }
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            try? handle.close()
        }
        io = channel
        let dispatchData = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: dispatchData, queue: queue) { [self] done, _, _ in
            if done { finish() }
        }
    }

    func waitUntilDone() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if finished { continuation.resume() } else { waiter = continuation }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard !finished else { return }
            io?.close(flags: .stop)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        io?.close()
        waiter?.resume()
        waiter = nil
    }
}
