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
    /// Actions waiting behind the running one; shown as "· N queued".
    var queuedCount: Int = 0
    let onTap: () -> Void

    var body: some View {
        HeaderPill(onTap: onTap) {
            RunningSpinner(reduceMotion: reduceMotion, size: 11)
            Text(queuedCount > 0 ? "Running · \(queuedCount) queued" : "Running")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiPrimary)
        }
        .help(queuedCount > 0
              ? "An action is running and \(queuedCount) more will follow — click to view progress"
              : "An action is running — click to view progress")
        .accessibilityLabel(queuedCount > 0
                            ? "Action running, \(queuedCount) queued. Open progress."
                            : "Action running. Open progress.")
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
    /// How many finished results the user hasn't collected. Zero means results
    /// are still available but all seen, which is a quieter state — not an
    /// absent one, because the pill is the only door back to them.
    let unviewed: Int
    let onTap: () -> Void

    /// `tray.fill`, not a checkmark. A checkmark means "done, nothing needed",
    /// which is the opposite of what this pill asks for — and the 24pt
    /// `checkmark.circle.fill` on the surface already means "finished, nothing
    /// kept", so one glyph would carry two contradictory meanings.
    private var label: String { unviewed > 1 ? "\(unviewed) Results" : "Result" }

    var body: some View {
        HeaderPill(onTap: onTap) {
            Image(systemName: "tray.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.caiPrimary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiPrimary)
                .monospacedDigit()
        }
        // Collected results stay reachable but stop competing for attention.
        .opacity(unviewed > 0 ? 1 : 0.55)
        .help(unviewed > 1 ? "\(unviewed) actions finished — click to see the results"
                           : "Click to see the result")
        .accessibilityLabel(unviewed > 1
            ? "\(unviewed) finished results. Open them."
            : "Finished result. Open it.")
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
    /// One kept result fills the view (→ from the list, or a chain's "Show in
    /// Cai"). Otherwise finished runs show as a list.
    let showsDetail: Bool
    let onBack: () -> Void
    /// Copies the result at this index and closes the panel (click or Return).
    let onCopy: (Int) -> Void

    @ObservedObject private var execution = ExecutionState.shared

    /// Every terminal state names the run that produced it: this surface is
    /// usually reached from the header pill long after the fact, where a bare
    /// "Finished" or "Failed" doesn't say what of. Status is carried by the
    /// glyph and body copy instead.
    private var headerTitle: String {
        if execution.isRunning { return "Running" }
        // Waiting behind an answer in the panel, which is not a tracked run.
        if !execution.queued.isEmpty { return "Queued" }
        if showsResultsList { return "Results" }
        // A kept result names the run that produced IT, which is not
        // necessarily the most recent run once the ring holds several.
        if let record { return record.actionName }
        // No kept result: a failure, or a run whose output was consumed. Named
        // by the run itself; "Failed"/"Finished" alone doesn't say what of.
        return execution.lastRunName ?? "Finished"
    }

    /// Whether the last run failed, and so has a message worth reading.
    private var hasFailure: Bool {
        if case .failed = execution.lastOutcome { return true }
        return false
    }

    /// The run list is up: something runs, or waits behind an answer.
    private var showsRunList: Bool {
        execution.isRunning || !execution.queued.isEmpty
    }

    /// Finished runs as a list, newest first, the failure on top.
    private var showsResultsList: Bool {
        ExecutionState.showsResultsList(execution.snapshot, showsDetail: showsDetail)
    }

    /// The kept result currently on screen, if any.
    ///
    /// Index -1 is the failure slot. Without it, a failed run whose ring still
    /// held earlier successes showed the newest SUCCESS and made the failure
    /// message unreachable — visible only in a 1.5s toast.
    private var record: ExecutionState.RunRecord? {
        guard !showsRunList, showsDetail else { return nil }
        let recent = execution.recent
        guard !recent.isEmpty else { return nil }
        let i = ExecutionState.clampResultIndex(
            resultIndex, recentCount: recent.count, hasFailure: hasFailure
        )
        guard i >= 0 else { return nil }   // showing the failure
        return recent[i]
    }

    /// Total pageable entries, including the failure slot.
    private var pageCount: Int {
        execution.recent.count + (hasFailure ? 1 : 0)
    }

    /// 1-based position of what's on screen, for the footer caption.
    private var pagePosition: Int {
        let i = ExecutionState.clampResultIndex(
            resultIndex, recentCount: execution.recent.count, hasFailure: hasFailure
        )
        return hasFailure ? i + 2 : i + 1
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
                    // A 60-char action name would otherwise wrap and grow the
                    // 38pt header row (DESIGN row heights).
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(headerTitle)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(Color.caiDivider)

            // Content — mirrors ResultView's loading/error layout so the panel's
            // states read as one system: a centered stack between two Spacers,
            // filling whatever height the window has, so a resized window shows more.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A `.transition` alone is inert here: the switch is driven by
                // `execution.snapshot` changing, which nothing wraps in
                // `withAnimation`, so progress → result would jump-cut.
                // DESIGN lists result reveals at easeOut 0.2s.
                .animation(.easeOut(duration: 0.2), value: record?.id)
                .animation(.easeOut(duration: 0.2), value: resultIndex)

            Spacer(minLength: 0)
            Divider().background(Color.caiDivider)

            HStack(spacing: 10) {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
                // One unit: the keys and the position bound together, at the
                // 10pt footer-hint weight (DESIGN typography) so the pager
                // never out-shouts Esc and Return. Rounded + monospaced
                // numerals so it doesn't jitter as it changes.
                if showsResultsList {
                    KeyboardHint(key: "\u{2192}", label: "Open")
                }
                if pageCount > 1 && record != nil {
                    KeyboardHint(
                        key: "\u{2190}\u{2192}",
                        label: "\(pagePosition) of \(pageCount)"
                    )
                    .monospacedDigit()
                }
                // Same affordance ResultView offers on a result, because it is
                // the same result.
                if record != nil || (showsResultsList && selectedIndex >= 0) {
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
        guard WindowController.isPanelVisible else { return }
        if showsResultsList {
            // The list shows every kept result, so opening it collects them.
            for record in execution.recent where !record.viewed {
                execution.markResultViewed(record.id)
            }
        } else if let record, !record.viewed {
            execution.markResultViewed(record.id)
        }
    }

    /// The highlighted row in the results list (-1 is the failure).
    private var selectedIndex: Int {
        ExecutionState.clampResultIndex(
            resultIndex, recentCount: execution.recent.count, hasFailure: hasFailure
        )
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
                // Fresh identity per record, so paging actually crossfades AND
                // the ScrollView starts at the top instead of inheriting the
                // previous record's scroll offset.
                .id(record.id)
                .transition(.opacity)
                .accessibilityLabel(
                    pageCount > 1
                        ? "Result \(pagePosition) of \(pageCount), from \(record.actionName)"
                        : "Result from \(record.actionName)"
                )
        } else if showsRunList {
            runList
        } else if showsResultsList {
            resultsList
        } else {
            centeredStatus
        }
    }

    /// One row per action: the running one, then what waits, in order. Rows
    /// carry the name and the start of the text each runs on, so two runs of
    /// one action can be told apart. No per-row controls: cancel is its own
    /// change, and reordering belongs to History.
    private var runList: some View {
        let queued = execution.queued
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let action = execution.runningAction {
                    // A chain on a step shows the step; otherwise the input.
                    runRow(name: action.name, subtitle: action.step.map(stepSubtitle) ?? action.input) {
                        ActionIconTile(isSelected: false) {
                            RunningSpinner(reduceMotion: reduceMotion, size: 14)
                        }
                    }
                } else {
                    // Only an answer in the panel holds the line without being
                    // a tracked run, so there is nothing to name here.
                    Text("Starts when the current answer finishes.")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }

                if !queued.isEmpty {
                    if execution.runningAction != nil {
                        Text("Queued")
                            .font(.system(size: 11))
                            .foregroundColor(.caiTextSecondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }
                    // Top to bottom is the order; no position numbers. Every
                    // queued row shows: the queue is uncapped and this scrolls.
                    ForEach(queued) { run in
                        runRow(name: run.name, subtitle: run.input) {
                            ActionIconTile(icon: run.icon)
                        }
                    }
                }
            }
            // Same insets as the action list, so the rows line up with it.
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    /// Finished runs, newest first, with a failure on top. The highlighted row
    /// moves with ↑↓; Return or a click copies it and closes the panel, → opens
    /// it in full. Same rows as the run list.
    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .failed(let message) = execution.lastOutcome {
                    runRow(name: execution.lastRunName ?? "Action", subtitle: message, selected: selectedIndex == -1) {
                        ActionIconTile(isSelected: false) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.caiError)
                        }
                    }
                    .onTapGesture { resultIndex = -1 }
                }
                ForEach(Array(execution.recent.enumerated()), id: \.element.id) { index, record in
                    runRow(name: record.actionName, subtitle: ExecutionState.inputPreview(record.text), selected: selectedIndex == index) {
                        ActionIconTile(isSelected: false) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.caiSuccess)
                        }
                    }
                    .onTapGesture { onCopy(index) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Copies this result")
                    .accessibilityAction { onCopy(index) }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    /// Laid out like `ActionRow` (icon tile, 13pt title, 11pt subtitle, same
    /// padding) so a queued action looks as it did where it was picked.
    private func runRow<Lead: View>(name: String, subtitle: String, selected: Bool = false, @ViewBuilder lead: () -> Lead) -> some View {
        HStack(spacing: 12) {
            lead()
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(name)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.caiPrimarySubtle : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "Step 2 of 3 · Save to Notes", or just the count when the step has no label.
    private func stepSubtitle(_ step: ExecutionState.StepProgress) -> String {
        let count = ExecutionState.stepCaption(index: step.index, total: step.total)
        return step.label.isEmpty ? count : "\(count) \u{00B7} \(step.label)"
    }

    @ViewBuilder
    private var centeredStatus: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                if case .failed(let message) = execution.lastOutcome {
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

/// The ←/→ observers for the run surface's result pager.
///
/// A `ViewModifier` rather than two more `.onReceive` calls on the action
/// window's body: that chain is long enough that adding to it tips the Swift
/// type-checker into "unable to type-check this expression in reasonable time".
/// Wrapping them gives them their own inference context.
struct RunResultPagingKeys: ViewModifier {
    /// Called with -1 for ←, +1 for →.
    let onPage: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .caiArrowLeft)) { _ in
                onPage(-1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .caiArrowRight)) { _ in
                onPage(1)
            }
    }
}
