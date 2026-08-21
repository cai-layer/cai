import SwiftUI

/// The "Running" pill shown in the action-panel header while an action is in
/// flight. Deliberately minimal per the design decision (2026-08-17): just a
/// spinner + the word "Running" (the action name lives in the progress view,
/// not the pill). Tapping opens `RunningView`. It sits as a sibling in the
/// header's flex row, never an overlay, so the content preview wraps beside it.
///
/// Indigo is earned here: the pill is an interactive, active-state affordance
/// (`caiPrimarySubtle` wash + `caiPrimary` content), matching Indigo discipline.
struct RunningPill: View {
    /// Render the spinner static when the user prefers reduced motion.
    let reduceMotion: Bool
    let onTap: () -> Void

    var body: some View {
        HeaderPill(onTap: onTap) {
            RunningSpinner(reduceMotion: reduceMotion, size: 11)
            Text("Running")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiPrimary)
        }
        .help("An action is running — click to view progress")
        .accessibilityLabel("Action running. Open progress.")
    }
}

/// The shell both header pills wear.
///
/// Extracted because `RunningPill` and `ResultReadyPill` are one control in two
/// states — same slot, same tap consequence — and the read only holds while
/// their shells are pixel-identical. Two copies of the padding/radius/fill was
/// a drift waiting to happen.
private struct HeaderPill<Content: View>: View {
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) { content() }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.caiPrimarySubtle)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// The "Result" pill that replaces `RunningPill` once a run finishes holding
/// output nothing consumed. It is the default sink's discoverability backbone:
/// the toast is gone in 1.5s, but this survives ⌥C reopen until the user looks
/// (or the next run starts), so a result is never merely announced.
///
/// Same indigo treatment as `RunningPill` — it is the same affordance in a
/// later state, and it acts, so indigo is earned. Deliberately NOT `caiSuccess`
/// green: that would invent a second chromatic interactive vocabulary for what
/// is one control.
struct ResultReadyPill: View {
    /// How many finished results are waiting. Pluralised with a count once more
    /// than one run has gone uncollected, so back-to-back background actions
    /// read as two things to collect rather than one.
    let count: Int
    let onTap: () -> Void

    private var label: String { count > 1 ? "\(count) Results" : "Result" }

    var body: some View {
        HeaderPill(onTap: onTap) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.caiPrimary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiPrimary)
                .monospacedDigit()
        }
        .help(count > 1 ? "\(count) actions finished — click to see the results"
                        : "An action finished — click to see the result")
        .accessibilityLabel(count > 1
            ? "\(count) finished results. Open them."
            : "Action finished with a result. Open it.")
    }
}

/// Spinner that respects reduced motion: an animating `ProgressView` normally,
/// a static glyph when motion is reduced. Reused by the pill and the view.
private struct RunningSpinner: View {
    let reduceMotion: Bool
    let size: CGFloat

    var body: some View {
        if reduceMotion {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.caiPrimary)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(size / 20)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// The run surface: progress while an action runs, its result when it finishes,
/// its error when it fails. Opened from the header pill (or automatically when a
/// foreground chain terminates in "Show in Cai").
///
/// Reads `ExecutionState`, so it updates live as the chain advances and then
/// switches to the terminal state in place — one screen for one run's lifecycle,
/// rather than a jump cut to a second view.
///
/// The result branch is the default sink's payoff (finding #18). Before it, a
/// chain ending on an LLM or shell step showed "This action has finished. See
/// the notification for the result." while the text itself had already been
/// discarded — the notification was a 60-character snippet and there was nothing
/// else to see. It now renders the actual output through the same `ResultBody`
/// that `ResultView` uses, with the same Enter-to-copy affordance.
struct RunningView: View {
    let reduceMotion: Bool
    /// Which kept result is on screen (0 = newest). Owned by the parent so the
    /// existing arrow-key plumbing can move through the ring.
    @Binding var resultIndex: Int
    let onBack: () -> Void

    @ObservedObject private var execution = ExecutionState.shared

    /// Every terminal state names the run that produced it: this surface is
    /// usually reached from the header pill long after the fact, where a bare
    /// "Finished" or "Failed" doesn't say what of. Status is carried by the
    /// glyph and body copy instead.
    private var headerTitle: String {
        if execution.isRunning { return "Running" }
        // A kept result names the run that produced IT, which is not
        // necessarily the most recent run once the ring holds several.
        if let record { return record.actionName }
        // No kept result: a failure, or a run whose output was consumed. Named
        // by the run itself; "Failed"/"Finished" alone doesn't say what of.
        return execution.lastRunName ?? "Finished"
    }

    /// The kept result currently on screen, if any.
    private var record: ExecutionState.RunRecord? {
        guard !execution.isRunning else { return nil }
        let recent = execution.recent
        guard !recent.isEmpty else { return nil }
        return recent[min(max(0, resultIndex), recent.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — mirrors the other sub-screens (icon · title).
            HStack(spacing: 10) {
                Image(systemName: record == nil ? "bolt.horizontal.circle" : "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.caiPrimary)
                Text(headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(Color.caiDivider)

            // Content — mirrors ResultView's loading/error layout so the panel's
            // states read as one system: a centered stack between two Spacers,
            // capped at the same 240pt content height.
            content
                .frame(maxWidth: .infinity, maxHeight: 240)
                // A `.transition` alone is inert here: the switch is driven by
                // `execution.snapshot` changing, which nothing wraps in
                // `withAnimation`, so progress → result would jump-cut.
                // DESIGN lists result reveals at easeOut 0.2s.
                .animation(.easeOut(duration: 0.2), value: record?.id)

            Spacer(minLength: 0)
            Divider().background(Color.caiDivider)

            HStack(spacing: 10) {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
                // "2 of 3" only once the ring holds more than one, with the
                // arrows that move through it. Rounded + monospaced numerals so
                // the caption doesn't jitter as it changes (DESIGN).
                if execution.recent.count > 1, record != nil {
                    KeyboardHint(key: "\u{2191}\u{2193}", label: "Results")
                    Text("\(min(resultIndex, execution.recent.count - 1) + 1) of \(execution.recent.count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.caiTextSecondary)
                        .monospacedDigit()
                }
                // Same affordance ResultView offers on a result, because it is
                // the same result.
                if record != nil {
                    KeyboardHint(key: "\u{21B5}", label: "Copy")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        // Looking at a result is what "collecting" it means, so the pill stops
        // advertising THAT record.
        //
        // Gated on the panel actually being on screen: `hideWindow` parks this
        // hierarchy alive in `cachedWindow` (that is what powers resume), so an
        // ordered-out run surface keeps observing and would otherwise mark a
        // result seen that nobody saw — silently clearing the only thing
        // advertising it.
        .onAppear { markVisibleRecordViewed() }
        .onChange(of: execution.snapshot) { _, _ in markVisibleRecordViewed() }
        .onChange(of: resultIndex) { _, _ in markVisibleRecordViewed() }
    }

    private func markVisibleRecordViewed() {
        guard WindowController.isPanelVisible, let record, !record.viewed else { return }
        execution.markResultViewed(record.id)
    }

    @ViewBuilder
    private var content: some View {
        if let record {
            // A real result gets the full scrollable pane, exactly as it would
            // have in ResultView had the action run in the foreground.
            //
            // Scope cut, deliberate: no "Send to" destination chips here yet,
            // unlike ResultView. Wiring them means routing `executeDestination`
            // into this view, and a recovered result can still be copied with
            // Enter. Noted as a follow-up rather than left as an accident.
            ResultBody(text: record.text)
                .transition(.opacity)
        } else {
            centeredStatus
        }
    }

    @ViewBuilder
    private var centeredStatus: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                if let action = execution.runningAction {
                    RunningSpinner(reduceMotion: reduceMotion, size: 16)

                    // Action name — primary, matches ResultView body text.
                    Text(action.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)

                    if let step = action.step {
                        VStack(spacing: 4) {
                            // "Step N of M" — rounded numerals, monospaced so the
                            // counter doesn't jitter as it advances (DESIGN).
                            Text(ExecutionState.stepCaption(index: step.index, total: step.total))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.caiTextSecondary)
                                .monospacedDigit()

                            // What this step is — a quiet, centered, wrapped
                            // subtitle (an inline-LLM step's label is its whole
                            // directive, so it must cap + wrap, never run to the
                            // edge). Padding + centering + 2-line cap match the
                            // ResultView error subtitle treatment.
                            if !step.label.isEmpty {
                                Text(step.label)
                                    .font(.system(size: 11))
                                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 32)
                            }
                        }
                    }
                } else if case .failed(let message) = execution.lastOutcome {
                    // The run ended in failure while this view was open. Same
                    // vocabulary as ResultView's error state (triangle + caiError
                    // orange — Cai has no red), with the message capped + wrapped.
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(.caiError)
                    Text("Action failed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                        .textSelection(.enabled)
                } else {
                    // Succeeded with nothing to show: either a destination
                    // consumed the output (the completion toast confirmed it) or
                    // the terminal step produced no text at all. Deliberately no
                    // "see the notification for the result" — a run that kept a
                    // result takes the branch above and shows it, so pointing at
                    // a toast here would be pointing at nothing.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.caiSuccess)
                    Text("This action has finished.")
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
