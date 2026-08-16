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

    /// How a finished run turned out. `.failed` carries a message to show.
    enum Outcome: Equatable {
        case succeeded
        case failed(String)
    }

    /// The full running state as a value, so transitions are pure and testable.
    struct Snapshot: Equatable {
        /// Nesting depth of in-flight runs. `> 0` means something is running.
        var depth: Int = 0
        /// Identity + step of the outermost run (nil when idle).
        var action: RunningAction?
        /// Accumulates during a run; committed to `lastOutcome` when it ends.
        /// Defaults to `.succeeded`; a reported failure (from any nesting level)
        /// wins, so a run whose sub-step failed reads as failed.
        var pendingOutcome: Outcome = .succeeded
        /// Outcome of the most recent finished run — what the progress view
        /// shows after the spinner stops. Nil until the first run ends; reset
        /// when the next run starts.
        var lastOutcome: Outcome?

        var isRunning: Bool { depth > 0 }
    }

    enum Event: Equatable {
        /// A run began. Only the outermost (`depth 0 -> 1`) sets the identity.
        case start(name: String)
        /// The running chain advanced to a new top-level step.
        case advance(StepProgress)
        /// A step/run failed with a user-facing message.
        case reportFailure(String)
        /// A run ended.
        case finish
    }

    /// Whether a newly triggered action may start, or should surface "busy".
    enum StartDecision: Equatable { case start, busy }

    @Published private(set) var snapshot = Snapshot()

    var isRunning: Bool { snapshot.isRunning }
    var runningAction: RunningAction? { snapshot.action }
    /// Outcome of the most recent finished run (nil while running / before any).
    var lastOutcome: Outcome? { snapshot.lastOutcome }

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
                next.pendingOutcome = .succeeded
                next.lastOutcome = nil
            }
            next.depth += 1
        case .advance(let step):
            next.action?.step = step
        case .reportFailure(let message):
            // Failure at any nesting level marks the whole run failed.
            next.pendingOutcome = .failed(message)
        case .finish:
            next.depth = max(0, next.depth - 1)
            if next.depth == 0 {
                next.lastOutcome = next.pendingOutcome
                next.action = nil
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

    func finish() {
        snapshot = Self.reduce(snapshot, .finish)
        BackgroundTaskTracker.shared.end()
    }
}
