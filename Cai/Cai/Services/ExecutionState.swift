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

    /// What a run produced, when nothing consumed it.
    ///
    /// This is the payload the default sink exists to preserve: before it, a
    /// chain ending on an LLM or shell step computed its final text and threw
    /// it away after building a toast snippet (finding #18).
    struct RunResult: Equatable {
        /// The originating action's name, for the result surface's title.
        let actionName: String
        /// The terminal step's output. Never empty — a blank result is no
        /// result (see `ResultRouting.route`), so it's never reported.
        let text: String
    }

    /// How a finished run turned out.
    ///
    /// `.succeeded` carries the run's unconsumed output, or nil when there was
    /// nothing to keep — either a destination consumed it (the completion toast
    /// is the confirmation) or the terminal step produced no text. Folding the
    /// result INTO the outcome rather than beside it keeps one commit path in
    /// `reduce`, and makes "a failed run has no result" true by construction.
    enum Outcome: Equatable {
        case succeeded(RunResult?)
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
        /// Whether the user has seen `lastOutcome`'s result. Drives the header
        /// pill's "collect me" state: a finished run holding an unviewed result
        /// keeps the pill on screen (across ⌥C reopen) instead of vanishing
        /// with the result unread, which is the bug wearing a costume. True
        /// when there is nothing to collect, so the pill stays quiet.
        var resultViewed: Bool = true

        var isRunning: Bool { depth > 0 }

        /// The finished run's unconsumed output, if it produced any.
        var lastResult: RunResult? {
            if case .succeeded(let result) = lastOutcome { return result }
            return nil
        }

        /// A result is waiting to be looked at. What keeps the pill visible.
        var hasUnviewedResult: Bool { lastResult != nil && !resultViewed }
    }

    enum Event: Equatable {
        /// A run began. Only the outermost (`depth 0 -> 1`) sets the identity.
        case start(name: String)
        /// The running chain advanced to a new top-level step.
        case advance(StepProgress)
        /// A step/run failed with a user-facing message.
        case reportFailure(String)
        /// The run produced output that no destination consumed. Last write
        /// wins across nesting levels, so a nested chain's terminal output
        /// (the innermost thing that actually ran last) is what the user gets.
        case produceResult(RunResult)
        /// A run ended.
        case finish
        /// The user looked at the finished run's result — clears the pill.
        case viewResult
    }

    /// Whether a newly triggered action may start, or should surface "busy".
    enum StartDecision: Equatable { case start, busy }

    @Published private(set) var snapshot = Snapshot()

    var isRunning: Bool { snapshot.isRunning }
    var runningAction: RunningAction? { snapshot.action }
    /// Outcome of the most recent finished run (nil while running / before any).
    var lastOutcome: Outcome? { snapshot.lastOutcome }
    /// The finished run's unconsumed output, if any. What the run surface shows.
    var lastResult: RunResult? { snapshot.lastResult }
    /// A finished run's result hasn't been looked at yet — keeps the pill up.
    var hasUnviewedResult: Bool { snapshot.hasUnviewedResult }

    // MARK: - Pure logic (unit-tested)

    /// Applies an event to a snapshot. Pure: no side effects, total over inputs.
    nonisolated static func reduce(_ snapshot: Snapshot, _ event: Event) -> Snapshot {
        var next = snapshot
        switch event {
        case .start(let name):
            // Only the outermost start owns the displayed identity; a nested
            // run (a chain inside an already-running action) just deepens the
            // count and keeps the outer name/step. A fresh run clears the prior
            // outcome and resets the pending one to success.
            if next.depth == 0 {
                next.action = RunningAction(name: name, step: nil)
                next.pendingOutcome = .succeeded(nil)
                next.lastOutcome = nil
                // A new run supersedes the previous result: the pill must not
                // advertise a stale one, and the old text is gone from the
                // surface either way.
                next.resultViewed = true
            }
            next.depth += 1
        case .advance(let step):
            next.action?.step = step
        case .reportFailure(let message):
            // Failure at any nesting level marks the whole run failed, and
            // discards any result reported before it. A partial payload sitting
            // under a failure banner invites the user to trust half an answer.
            next.pendingOutcome = .failed(message)
        case .produceResult(let result):
            // A run already marked failed keeps its failure: a later step's
            // output can't un-fail it. Otherwise the newest report wins, so a
            // nested chain's terminal output beats its caller's.
            if case .succeeded = next.pendingOutcome {
                next.pendingOutcome = .succeeded(result)
            }
        case .finish:
            next.depth = max(0, next.depth - 1)
            if next.depth == 0 {
                next.lastOutcome = next.pendingOutcome
                next.action = nil
                // Only a run that actually kept output has something to
                // collect; anything else leaves the pill quiet.
                next.resultViewed = next.lastResult == nil
            }
        case .viewResult:
            next.resultViewed = true
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

    func start(name: String) {
        snapshot = Self.reduce(snapshot, .start(name: name))
        BackgroundTaskTracker.shared.start()
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
    func reportResult(_ result: RunResult) {
        snapshot = Self.reduce(snapshot, .produceResult(result))
    }

    /// The user opened the run surface — stop advertising the result.
    func markResultViewed() {
        snapshot = Self.reduce(snapshot, .viewResult)
    }

    func finish() {
        snapshot = Self.reduce(snapshot, .finish)
        BackgroundTaskTracker.shared.end()
    }
}
