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
        Button(action: onTap) {
            HStack(spacing: 5) {
                RunningSpinner(reduceMotion: reduceMotion, size: 11)
                Text("Running")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiPrimary)
            }
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
        .help("An action is running — click to view progress")
        .accessibilityLabel("Action running. Open progress.")
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

/// Live progress view for the running action, opened from the header pill.
/// Reads `ExecutionState` so it updates as the chain advances, and reflects
/// completion when the run ends (the pill disappears at the same moment). The
/// final result surfacing into a full result view is the separate History /
/// "Show in Cai" work; this view is the progress signal.
struct RunningView: View {
    let reduceMotion: Bool
    let onBack: () -> Void

    @ObservedObject private var execution = ExecutionState.shared

    private var headerTitle: String {
        if execution.isRunning { return "Running" }
        if case .failed = execution.lastOutcome { return "Failed" }
        return "Finished"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — mirrors the other sub-screens (icon · title).
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle")
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

            Spacer(minLength: 0)
            Divider().background(Color.caiDivider)

            HStack {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
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
                    // Succeeded — safe to show the success check now that the
                    // outcome is known. The result itself lands in the toast.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.caiSuccess)
                    Text("This action has finished.")
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextSecondary)
                        .multilineTextAlignment(.center)
                    Text("See the notification for the result.")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary.opacity(0.6))
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
