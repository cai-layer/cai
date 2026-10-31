import Foundation

/// The line actions wait in, one at a time. Values a later History surface
/// needs (the queued names, which run waited) live on `ExecutionState`; this
/// owns only what can't be a value: the tail of the serial chain.
///
/// Each item's task awaits the one before it, so order is structural: there is
/// no registry to drain and no pump to forget. Admission and the place in line
/// are taken synchronously inside `run` / `acquireTurn`, before any await, so a
/// second trigger can't slip in between "is it busy?" and "I'm running".
@MainActor
enum RunQueue {
    /// The last item in line. Each new item waits for it, then becomes it.
    private static var tail: Task<Void, Never>?

    /// Items admitted and not yet finished, the running one included.
    private static var outstanding = 0
    static var isBusy: Bool { outstanding > 0 }

    /// Runs `work` as a tracked run after whatever is ahead of it. `work`
    /// receives the run's id for result reports; `start` and `finish` happen
    /// here, so the body must not call them. `input` is the text the action
    /// runs on, shown in the run list; it is never posted in a toast.
    static func run(name: String, input: String, icon: String, work: @escaping @MainActor (_ runId: UUID) async -> Void) {
        let id = UUID()
        let preview = ExecutionState.inputPreview(input)
        if isBusy {
            ExecutionState.shared.enqueue(.init(id: id, name: name, input: preview, icon: icon))
            ToastQueue.post("Queued: \(name)", outcome: .progress)
        }
        outstanding += 1
        let previous = tail
        tail = Task { @MainActor in
            defer { outstanding -= 1 }
            await previous?.value
            let runId = ExecutionState.shared.start(name: name, id: id, input: preview)
            defer { ExecutionState.shared.finish() }
            await work(runId)
        }
    }

    /// Holds the engine for a foreground answer (the ones `ResultView` shows)
    /// without starting a tracked run: no pill, no queued row, and an unread
    /// failure on the run surface stays unread. Waits for everything ahead,
    /// then holds the line until `release()`.
    ///
    /// A caller that goes away while waiting (Esc) still waits for the item
    /// ahead before its own `checkCancellation` throws and it lets go; the
    /// items behind it wait for that item regardless, so order is unaffected.
    static func acquireTurn() async throws -> Turn {
        let (gate, open) = AsyncStream<Void>.makeStream()
        outstanding += 1
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            for await _ in gate {}
        }
        let turn = Turn(open: open)
        await previous?.value
        do {
            try Task.checkCancellation()
        } catch {
            turn.release()
            throw error
        }
        return turn
    }

    /// A foreground answer's hold on the line. `release()` is idempotent.
    final class Turn {
        private var open: AsyncStream<Void>.Continuation?

        fileprivate init(open: AsyncStream<Void>.Continuation) {
            self.open = open
        }

        @MainActor
        func release() {
            guard let open else { return }
            self.open = nil
            open.finish()
            RunQueue.outstanding -= 1
        }
    }

    /// Paste-back for work that may have waited. A run that sat in the queue
    /// was triggered on a selection the user has since moved away from, so it
    /// copies instead and lets the caller say "⌘V to paste". Every other run
    /// pastes as before (`pasteResult` already copies if the app changed).
    static func pasteBack(_ text: String, toBundleId bundleId: String?) async -> ClipboardService.PasteOutcome {
        if ExecutionState.shared.currentRunWaited {
            SystemActions.copyToClipboard(text)
            return .copiedForManualPaste
        }
        return await withCheckedContinuation { continuation in
            ClipboardService.shared.pasteResult(text, toBundleId: bundleId) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    /// `generator` run in its turn, holding the line until it returns.
    static func inTurn(_ generator: @escaping () async throws -> String) -> () async throws -> String {
        {
            let turn = try await acquireTurn()
            defer { turn.release() }
            return try await generator()
        }
    }

    /// The stream variant: the line is held until the stream ends or its
    /// consumer goes away, since the model keeps generating until then.
    static func inTurn(
        _ streamGenerator: @escaping () async throws -> AsyncThrowingStream<String, Error>
    ) -> () async throws -> AsyncThrowingStream<String, Error> {
        {
            let turn = try await acquireTurn()
            let upstream: AsyncThrowingStream<String, Error>
            do {
                upstream = try await streamGenerator()
            } catch {
                turn.release()
                throw error
            }
            return AsyncThrowingStream { continuation in
                let forward = Task { @MainActor in
                    defer { turn.release() }
                    do {
                        for try await chunk in upstream { continuation.yield(chunk) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                // Esc closes the view: stop forwarding, which ends the
                // upstream iteration and cancels the generation with it.
                continuation.onTermination = { _ in forward.cancel() }
            }
        }
    }
}
