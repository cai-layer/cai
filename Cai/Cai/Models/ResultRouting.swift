import Foundation

/// Where a finished run's output goes.
///
/// The bug this exists to fix (finding #18) was not that `ResultView` couldn't
/// render a chain's output — it was that nothing in the model distinguished
/// **"a destination consumed the output"** (Notes, paste-back, a webhook took
/// it; the completion toast is the right and sufficient signal) from **"the
/// terminal step produced text nobody took"** (silently discarded). Without
/// that distinction there was no place to even ask the question, so the answer
/// was always "drop it".
///
/// Pure and `nonisolated`, so the decision is table-tested (`ResultRoutingTests`)
/// rather than only exercised by running real chains and watching a 1.5s pill.
enum ResultRouting: Equatable {
    /// No text at all — a `url` step that opened a link, or an empty shell.
    /// Nothing to keep and nothing to show.
    case nothing
    /// A destination took the output. Unchanged behaviour: the side-effect
    /// happened and the completion toast confirms it.
    case consumed
    /// Keep it as the finished run's result, quietly. The header pill holds
    /// its "collect me" state (across ⌥C reopen) and the toast still fires;
    /// no window opens and no focus is taken.
    case record
    /// Keep it AND bring the panel up on it now. Only reached when the run was
    /// foreground and its chain explicitly terminates in "Show in Cai" — the
    /// user asked for the window, so opening it isn't theft.
    case showInPanel

    /// What the run's last-executed step was, from the router's point of view.
    ///
    /// Derived from the step that *actually ran last*, which is not the same as
    /// the last element of the top-level step list: `ChainExecutor` recurses
    /// depth-first into a resolved action's own `next:` after running it, so a
    /// chain `[Summarize, Notes]` where Notes has `next: [Translate]` ends on an
    /// LLM step, not on Notes.
    enum TerminalStep: Equatable {
        /// A destination that does something with the text (AppleScript,
        /// webhook, deeplink, shell, paste-back, clipboard copy).
        case consumingDestination
        /// The "Show in Cai" destination — a no-op sink whose entire meaning is
        /// "don't consume this, the panel takes it".
        case showInCai
        /// An LLM step, a shell step, an Apple Shortcut, a built-in transform:
        /// anything whose output is just text handed back to the chain.
        case producesText
    }

    /// Decides where the output goes.
    ///
    /// - Parameters:
    ///   - text: the terminal step's output.
    ///   - terminal: what ran last (see `TerminalStep`).
    ///   - runInBackground: the originating action's own `runInBackground`
    ///     flag — *the user's intent*, not the execution path. Chains are
    ///     always dispatched on the background path today (they dismiss the
    ///     panel at trigger), so reading the path here would make
    ///     `.showInPanel` unreachable and "Show in Cai" dead code.
    nonisolated static func route(
        text: String,
        terminal: TerminalStep,
        runInBackground: Bool
    ) -> ResultRouting {
        // A consuming destination wins over everything, including the
        // background flag: the output already went somewhere the user chose,
        // so there is nothing to rescue and nothing to show.
        if terminal == .consumingDestination { return .consumed }

        // Whitespace-only output is no output. Reported results are never
        // empty, so the run surface never shows a blank pane.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothing
        }

        // `runInBackground` ALWAYS wins over showing a window — that toggle is
        // the user saying "stay out of my way", and it outranks a chain that
        // ends in "Show in Cai". The result is still kept; it just waits.
        if runInBackground { return .record }

        // Foreground + an explicit "Show in Cai" terminator: the run asked for
        // the panel. This is the only path that opens a window on its own.
        if terminal == .showInCai { return .showInPanel }

        // The implicit fallback, and the actual fix for #18: text nobody took
        // is never lost, and never interrupts.
        return .record
    }
}
