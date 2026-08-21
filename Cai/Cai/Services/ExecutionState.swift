import Foundation

/// Observable "is an action running" state the UI can read — the substrate for
/// the in-progress indicator (the header "Running" pill and its progress view).
///
/// Before this, action execution was fire-and-forget: `BackgroundTaskTracker`
/// counted in-flight work for the menu-bar blink, but nothing carried *which*
/// action or *which step*, and reopening ⌥C mid-run showed nothing. This adds
/// that identity + step, and keeps `BackgroundTaskTracker` in lockstep so the
/// ambient menu-bar signal is unchanged.
///
/// **v1 is one action at a time (no queue).** A new user-triggered action while
/// one is running should surface a *busy* state, never silently drop — see
/// `startDecision`. Internal nesting (a chain that runs inside an already-running
/// action) is safe: the depth counter mirrors `BackgroundTaskTracker`'s proven
/// nest-safe pattern, and only the outermost `start` sets the displayed identity.
///
/// The state machine (`reduce`), the start-vs-busy decision (`startDecision`),
/// and the step caption (`stepCaption`) are pure, `nonisolated static` functions
/// so they're table-tested (`ExecutionStateTests`) rather than only exercised in
/// the live app.
@MainActor
final class ExecutionState: ObservableObject {
    static let shared = ExecutionState()

    private init() {}

    /// Progress through a chain's top-level steps. `index` is 1-based.
    struct StepProgress: Equatable {
        let index: Int
        let total: Int
        let label: String
    }

    /// The action currently running, for display. The pill shows only "Running"
    /// (the name lives in the progress/result view), but the progress view reads
    /// `name` and `step` from here.
    struct RunningAction: Equatable {
        var name: String
        var step: StepProgress?
    }

    /// One finished run's kept output.
    ///
    /// `id` is the run's own id, so a late report from a run that already ended
    /// can be rejected rather than landing on whatever is running now.
    struct RunRecord: Equatable, Identifiable {
        let id: UUID
        let actionName: String
        let text: String
        var viewed: Bool
    }

    /// How a finished run turned out.
    ///
    /// `.succeeded` carries the run's unconsumed output — the payload the
    /// default sink exists to preserve, since a chain ending on an LLM or shell
    /// step used to compute its final text and throw it away after building a
    /// toast snippet (finding #18). It is nil when there was nothing to keep:
    /// either a destination consumed the output (the completion toast is the
    /// confirmation) or the terminal step produced no text. Never empty when
    /// non-nil — a blank result is no result, see `ResultRouting.route`.
    ///
    /// Folding the result INTO the outcome rather than beside it keeps one
    /// commit path in `reduce`, and makes "a failed run has no result" true by
    /// construction rather than by discipline.
    enum Outcome: Equatable {
        case succeeded(String?)
        case failed(String)
    }

    /// The full running state as a value, so transitions are pure and testable.
    struct Snapshot: Equatable {
        /// Nesting depth of in-flight runs. `> 0` means something is running.
        var depth: Int = 0
        /// Identity + step of the outermost run (nil when idle).
        var action: RunningAction?
        /// Accumulates during a run; committed to `lastOutcome` when it ends.
        /// Defaults to `.succeeded(nil)`; a reported failure (from any nesting
        /// level) wins, so a run whose sub-step failed reads as failed.
        var pendingOutcome: Outcome = .succeeded(nil)
        /// Outcome of the most recent finished run — what the progress view
        /// shows after the spinner stops. Nil until the first run ends; reset
        /// when the next run starts.
        var lastOutcome: Outcome?
        /// Name of the most recent run, kept AFTER it finishes (unlike
        /// `action`, which clears). The run surface is usually reached from the
        /// header pill long after the fact, where "Finished" or "Failed" alone
        /// doesn't say what of.
        var lastRunName: String?
        /// Identity of the in-flight run, minted at the outermost `start` and
        /// cleared at the outermost `finish`. Every result report carries it, so
        /// a callback that resolves after its run ended (a paste-back
        /// completion, a stray continuation) is dropped instead of being
        /// committed against whatever run happens to be live.
        var runId: UUID?
        /// Finished runs that kept output, newest first, capped at
        /// `maxRecent`. A ring rather than one slot: two background actions
        /// back to back used to destroy the first one's output before the user
        /// could collect it, which was the original bug surviving for the
        /// back-to-back case.
        var recent: [RunRecord] = []

        var isRunning: Bool { depth > 0 }

        /// The newest kept result. The run surface opens here.
        var lastResult: String? { recent.first?.text }

        /// Results the user hasn't looked at. Drives the header pill, which
        /// stays up (across ⌥C reopen) until they are collected.
        var unviewedCount: Int { recent.filter { !$0.viewed }.count }

        var hasUnviewedResult: Bool { unviewedCount > 0 }
    }

    enum Event: Equatable {
        /// A run began. Only the outermost (`depth 0 -> 1`) sets the identity.
        case start(name: String, id: UUID)
        /// The running chain advanced to a new top-level step.
        case advance(StepProgress)
        /// A step/run failed with a user-facing message.
        case reportFailure(String)
        /// The run produced output that no destination consumed. Carries the
        /// run's id; a report whose id doesn't match the live run is stale and
        /// dropped. Last write wins within a run, so a nested chain's terminal
        /// output (the innermost thing that actually ran last) is what lands.
        case produceResult(text: String, runId: UUID)
        /// A run ended.
        case finish
        /// The user looked at this result — stops the pill advertising it.
        case viewResult(id: UUID)
    }

    /// Whether a newly triggered action may start, or should surface "busy".
    enum StartDecision: Equatable { case start, busy }

    /// Cap on kept results. Session-only and deliberately small: this is a
    /// collection buffer so back-to-back runs don't eat each other, not the
    /// History surface (which is its own tracked work).
    static let maxRecent = 5

    @Published private(set) var snapshot = Snapshot()

    var isRunning: Bool { snapshot.isRunning }
    var runningAction: RunningAction? { snapshot.action }
    /// Outcome of the most recent finished run (nil while running / before any).
    var lastOutcome: Outcome? { snapshot.lastOutcome }
    /// The newest kept result. What the run surface opens on.
    var lastResult: String? { snapshot.lastResult }
    /// Name of the most recent run, surviving its completion.
    var lastRunName: String? { snapshot.lastRunName }
    /// Finished runs holding output, newest first.
    var recent: [RunRecord] { snapshot.recent }
    /// Results not yet looked at — keeps the pill up and drives its count.
    var unviewedCount: Int { snapshot.unviewedCount }
    var hasUnviewedResult: Bool { snapshot.hasUnviewedResult }

    // MARK: - Pure logic (unit-tested)

    /// Applies an event to a snapshot. Pure: no side effects, total over inputs.
    nonisolated static func reduce(_ snapshot: Snapshot, _ event: Event) -> Snapshot {
        var next = snapshot
        switch event {
        case .start(let name, let id):
            // Only the outermost start owns the displayed identity; a nested
            // run (a chain inside an already-running action) just deepens the
            // count and keeps the outer name/step. A fresh run clears the prior
            // outcome and resets the pending one to success.
            if next.depth == 0 {
                next.action = RunningAction(name: name, step: nil)
                next.lastRunName = name
                next.runId = id
                next.pendingOutcome = .succeeded(nil)
                next.lastOutcome = nil
                // `recent` is deliberately NOT cleared here — an uncollected
                // result from the previous run survives into the ring.
            }
            next.depth += 1
        case .advance(let step):
            next.action?.step = step
        case .reportFailure(let message):
            // Failure at any nesting level marks the whole run failed, and
            // discards any result reported before it. A partial payload sitting
            // under a failure banner invites the user to trust half an answer.
            next.pendingOutcome = .failed(message)
        case .produceResult(let text, let runId):
            // Stale report: the run that produced this text already ended, so
            // committing it now would either vanish (depth 0) or be attributed
            // to whatever is running instead. Drop it.
            guard let live = next.runId, live == runId else { return next }
            // A run already marked failed keeps its failure: a later step's
            // output can't un-fail it. Otherwise the newest report wins, so a
            // nested chain's terminal output beats its caller's.
            if case .succeeded = next.pendingOutcome {
                next.pendingOutcome = .succeeded(text)
            }
        case .finish:
            next.depth = max(0, next.depth - 1)
            if next.depth == 0 {
                next.lastOutcome = next.pendingOutcome
                next.action = nil
                // Only a run that actually kept output joins the ring; a
                // consumed or empty one leaves the pill quiet.
                if case .succeeded(let text?) = next.pendingOutcome {
                    next.recent.insert(
                        RunRecord(
                            id: next.runId ?? UUID(),
                            actionName: next.lastRunName ?? "Action",
                            text: text,
                            viewed: false
                        ),
                        at: 0
                    )
                    if next.recent.count > Self.maxRecent {
                        next.recent.removeLast(next.recent.count - Self.maxRecent)
                    }
                }
                next.runId = nil
            }
        case .viewResult(let id):
            if let i = next.recent.firstIndex(where: { $0.id == id }) {
                next.recent[i].viewed = true
            }
        }
        return next
    }

    /// v1 single-action rule: a new user-triggered action is `.busy` if one is
    /// already running, else `.start`. (Internal nesting doesn't go through this
    /// — only the executeAction entry point does.)
    nonisolated static func startDecision(isRunning: Bool) -> StartDecision {
        isRunning ? .busy : .start
    }

    /// "Step N of M" caption for the progress view. Clamped so a malformed
    /// (index/total) never reads worse than "Step 1 of 1".
    nonisolated static func stepCaption(index: Int, total: Int) -> String {
        let safeTotal = max(1, total)
        let safeIndex = min(max(1, index), safeTotal)
        return "Step \(safeIndex) of \(safeTotal)"
    }

    // MARK: - Mutations (thin; keep BackgroundTaskTracker in lockstep)

    /// Begins a run and returns its id. Callers hold the id and pass it back to
    /// `reportResult`, so a report that resolves after the run ended is dropped
    /// rather than landing on the next one.
    @discardableResult
    func start(name: String) -> UUID {
        let id = UUID()
        snapshot = Self.reduce(snapshot, .start(name: name, id: id))
        BackgroundTaskTracker.shared.start()
        return id
    }

    func advance(index: Int, total: Int, label: String) {
        snapshot = Self.reduce(snapshot, .advance(StepProgress(index: index, total: total, label: label)))
    }

    /// Marks the current run failed with a user-facing message. Committed to
    /// `lastOutcome` when the outermost run finishes. Safe to call before the
    /// paired `finish()` (which the tracked paths run in `defer`).
    func reportFailure(_ message: String) {
        snapshot = Self.reduce(snapshot, .reportFailure(message))
    }

    /// Records output that no destination consumed, so the finished run has a
    /// result to show instead of a 60-character toast snippet. Safe to call
    /// before the paired `finish()`; the reducer commits it there.
    func reportResult(_ text: String, for runId: UUID) {
        snapshot = Self.reduce(snapshot, .produceResult(text: text, runId: runId))
    }

    /// The user looked at this result — stop advertising it on the pill.
    func markResultViewed(_ id: UUID) {
        snapshot = Self.reduce(snapshot, .viewResult(id: id))
    }

    func finish() {
        snapshot = Self.reduce(snapshot, .finish)
        BackgroundTaskTracker.shared.end()
    }
}
