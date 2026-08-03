import CaiActionCore
import SwiftUI

/// The approval sheet: the one place an agent-authored action becomes real.
///
/// Hierarchy is payload first, deliberately. The name is what an attacker
/// controls and the payload is what actually runs, so the command sits at the
/// top in monospace, untruncated, and the name is metadata below it. Escalated
/// proposals add an orange callout per risk and an acknowledgment checkbox that
/// gates Approve, so a flow-state click cannot complete one.
///
/// Layout follows `docs/design/DESIGN.md`: 540pt frosted window, 20pt radius,
/// `caiPrimary` on Approve and nowhere else, `caiError` (orange) hairline and
/// 12% band on the callout only. No red exists in this system and none is
/// introduced here.
struct ActionReviewView: View {

    @ObservedObject var store: PendingChangeStore
    @ObservedObject private var settings = CaiSettings.shared
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    /// Reasons the user has ticked for the proposal on screen. Cleared whenever
    /// the queue advances so the next proposal starts from zero: an
    /// acknowledgment is about one payload, never inherited by the next.
    @State private var acknowledged: Set<EscalationReason> = []

    /// False for a moment after the card changes. Approve owns the Return key
    /// and the queue advances in place, so without this a held or double
    /// Return carries straight into the next proposal, and a proposal
    /// arriving under the cursor can catch a click meant for the last one.
    @State private var isArmed = false

    /// Which proposal is on screen. Browsing is allowed; deciding is still one
    /// at a time, and every card keeps its own acknowledgments.
    @State private var browseIndex = 0

    private var proposal: PendingProposal? {
        guard !store.pending.isEmpty else { return nil }
        return store.pending[ActionReviewPresentation.clampedQueueIndex(browseIndex, count: store.pending.count)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let proposal {
                header(for: proposal)
                content(for: proposal)
                footer(for: proposal)
            } else {
                emptyState
            }
        }
        .frame(width: 540)
        .background(VisualEffectBackground(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Keyed on the whole proposal, not its id: a writer can rewrite the
        // same file in place, keeping the id while the payload changes. Ticks
        // belong to the bytes the user read, not to a filename.
        .onChange(of: proposal) { _ in acknowledged = [] }
        .onChange(of: store.pending.count) { count in
            browseIndex = ActionReviewPresentation.clampedQueueIndex(browseIndex, count: count)
        }
        // Left and right step the queue. Return and Esc are taken by Approve
        // and defer, and the arrows are the macOS convention for moving
        // through a set of items anyway.
        .background {
            VStack {
                Button("") { if canGoBack { browseIndex -= 1 } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { if canGoForward { browseIndex += 1 } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .task(id: proposal) {
            isArmed = false
            try? await Task.sleep(nanoseconds: 350_000_000)
            isArmed = true
        }
    }

    // MARK: - Header

    private func header(for proposal: PendingProposal) -> some View {
        HStack(spacing: 8) {
            Text(ActionReviewPresentation.windowTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            Spacer()

            if let counter = ActionReviewPresentation.queueCounter(
                index: browseIndex, total: store.pending.count
            ) {
                HStack(spacing: 2) {
                    queueStepButton(systemName: "chevron.left", enabled: canGoBack, help: "Previous proposal") {
                        browseIndex -= 1
                    }

                    Text(counter)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.caiTextSecondary)
                        .padding(.horizontal, 4)
                        .accessibilityLabel("Proposal \(counter)")

                    queueStepButton(systemName: "chevron.right", enabled: canGoForward, help: "Next proposal") {
                        browseIndex += 1
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.caiSurface.opacity(0.6)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var canGoBack: Bool { browseIndex > 0 }
    private var canGoForward: Bool { browseIndex < store.pending.count - 1 }

    /// A chevron the size of the counter beside it. Disabled rather than hidden
    /// at the ends, so the control does not change width as you step.
    private func queueStepButton(
        systemName: String,
        enabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(enabled ? .caiTextSecondary : .caiTextSecondary.opacity(0.25))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for proposal: PendingProposal) -> some View {
        let validated = proposal.validated

        VStack(alignment: .leading, spacing: 12) {
            // One frame, not two. A create shows its payload; an update shows
            // the diff, and the diff renders the whole action, so the payload
            // is always in it as context lines however small the patch. Adding
            // the payload block underneath would put the same bytes on screen
            // twice with nothing saying they are the same bytes, leaving the
            // user to decide which copy to trust.
            if let before = validated.before {
                diffBlock(before: before, after: validated.after, changed: validated.changedFields)
            } else {
                payloadBlock(for: validated.after)
            }

            if !validated.after.next.isEmpty {
                chainBlock(for: validated.after)
            }

            callout(for: validated.escalationReasons)

            metadata(for: proposal)

            if !validated.warnings.isEmpty {
                warnings(validated.warnings)
            }

            if validated.tier == .escalated {
                acknowledgments(for: validated.escalationReasons)
            }
        }
        .padding(.horizontal, 16)
    }

    /// The hero. Monospace, scrollable, never truncated: the user has to be
    /// able to read every character that will run.
    private func payloadBlock(for action: ActionSnapshot) -> some View {
        ScrollView {
            Text(action.value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.caiTextPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.caiSurface.opacity(0.6)))
        .accessibilityElement()
        .accessibilityLabel(ActionReviewPresentation.payloadLabel(for: action.type))
        .accessibilityValue(action.value)
    }

    /// One block per chain step with the referenced item's kind resolved, so a
    /// chain cannot hide a shell step behind a friendly name.
    private func chainBlock(for action: ActionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Then runs")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)

            ForEach(ActionReviewPresentation.chainSteps(action.next, known: settings.knownActions)) { step in
                HStack(spacing: 8) {
                    Text("\(step.index + 1)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.caiTextSecondary)
                        .frame(width: 14)

                    Text(step.label)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.caiTextPrimary)
                        .lineLimit(2)

                    Spacer()

                    Text(step.kind)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.caiSurface.opacity(0.6)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(step.index + 1), \(step.label), \(step.kind)")
            }
        }
    }

    /// The whole update as one diff, in the shape every developer reads
    /// without thinking: line numbers, `−`/`+`, tinted rows, and a header
    /// naming each field the way a file path heads a hunk.
    ///
    /// One frame, not one per field. A card per field nested cards inside
    /// cards and made two small edits look like two separate decisions, when
    /// the user is approving exactly one thing.
    ///
    /// Every field renders identically, one line or thirty: a sheet that
    /// changes its diff format depending on the payload makes the reader
    /// re-learn it each time, and skimming is the failure this surface cannot
    /// afford. Nothing is collapsed or truncated; long payloads scroll.
    private func diffBlock(before: ActionSnapshot, after: ActionSnapshot, changed: [ActionField]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Proposed changes")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)

            ScrollView {
                diffLines(
                    before: ActionReviewPresentation.renderDocument(before),
                    after: ActionReviewPresentation.renderDocument(after)
                )
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.caiSurface.opacity(0.6)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Proposed changes to \(changed.map(ActionReviewPresentation.fieldLabel).joined(separator: ", "))"
            )
        }
    }

    private func diffLines(before: String, after: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ActionReviewPresentation.lineDiff(before: before, after: after)) { line in
                HStack(alignment: .top, spacing: 0) {
                    Text(line.oldNumber.map(String.init) ?? "")
                        .frame(width: 26, alignment: .trailing)
                    Text(line.newNumber.map(String.init) ?? "")
                        .frame(width: 26, alignment: .trailing)
                        .padding(.trailing, 8)
                    Text(line.marker)
                        .frame(width: 10, alignment: .leading)
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundColor(.caiTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
                .padding(.vertical, 1)
                .padding(.horizontal, 8)
                .background(diffTint(for: line.kind))
            }
        }
        .padding(.vertical, 4)
    }

    private func diffTint(for kind: ActionReviewPresentation.DiffLine.Kind) -> Color {
        switch kind {
        case .added: return .caiDiffAdded.opacity(0.14)
        case .removed: return .caiDiffRemoved.opacity(0.12)
        case .context: return .clear
        }
    }

    /// One band, however many risks. Stacking a sentence per risk repeats
    /// "This action" down the sheet and pushes the buttons off the fold, so
    /// two or more collapse into a single headed list.
    @ViewBuilder
    private func callout(for reasons: [EscalationReason]) -> some View {
        switch ActionReviewPresentation.callout(for: reasons) {
        case .none:
            EmptyView()

        case .sentence(let text):
            calloutBand {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

        case .grouped(let header, let bullets):
            calloutBand {
                VStack(alignment: .leading, spacing: 4) {
                    Text(header)
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextPrimary)

                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextSecondary)
                            Text(bullet)
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(header) \(bullets.joined(separator: ", "))")
        }
    }

    /// The orange band itself: `caiError` at 12% with a hairline, and the only
    /// place orange appears on this sheet.
    private func calloutBand<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.caiError)

            content()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.caiError.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.caiError.opacity(0.5), lineWidth: 1))
        )
    }

    private func metadata(for proposal: PendingProposal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Single line by construction: the validator strips control
            // characters and caps the length, and this is the belt to that
            // brace. A client name is attacker-controlled text sitting in
            // Cai's own voice, one line above the payload.
            Text(ActionReviewPresentation.provenanceLine(
                client: proposal.provenance.client,
                authoredAt: proposal.provenance.authoredAt,
                now: Date()
            ))
            .font(.system(size: 11))
            .foregroundColor(.caiTextSecondary)
            .lineLimit(1)
            .truncationMode(.middle)

            HStack(spacing: 16) {
                Text("Name: \(proposal.validated.after.name)")
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextPrimary)
                    .lineLimit(1)

                if proposal.validated.after.type == .prompt {
                    Text("Runs with: \(settings.modelProvider.rawValue)")
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextSecondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func warnings(_ warnings: [ActionWarning]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The habituation defense. One box per risk, all of them required.
    private func acknowledgments(for reasons: [EscalationReason]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(reasons, id: \.self) { reason in
                Toggle(isOn: Binding(
                    get: { acknowledged.contains(reason) },
                    set: { isOn in
                        if isOn { acknowledged.insert(reason) } else { acknowledged.remove(reason) }
                    }
                )) {
                    Text(ActionReviewPresentation.acknowledgment(for: reason))
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: - Footer

    private func footer(for proposal: PendingProposal) -> some View {
        let canApprove = isArmed && ActionReviewPresentation.canApprove(
            tier: proposal.validated.tier,
            reasons: proposal.validated.escalationReasons,
            acknowledged: acknowledged
        )

        return HStack(spacing: 8) {
            Spacer()

            Button(ActionReviewPresentation.rejectButton) {
                store.reject(proposal)
                closeIfQueueEmpty()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(ActionReviewPresentation.approveButton) {
                approve(proposal)
            }
            .buttonStyle(.borderedProminent)
            .tint(.caiPrimary)
            .controlSize(.large)
            .disabled(!canApprove)
            // Return approves, and stays inert on the escalated tier until
            // every box is checked: the disabled button swallows the key.
            .keyboardShortcut(.defaultAction)

            // Esc defers. The window closes, the badge and the queue stay:
            // rejecting is always an explicit click, never a dismissal.
            Button("") { onClose() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - Actions

    private func approve(_ proposal: PendingProposal) {
        let isUpdate = proposal.validated.isUpdate

        switch store.approve(proposal, acknowledged: acknowledged) {
        case .approved:
            NotificationCenter.default.post(
                name: .caiShowToast,
                object: nil,
                userInfo: ["message": ActionReviewPresentation.approvedToast(isUpdate: isUpdate)]
            )
            closeIfQueueEmpty()

        case .refused:
            // The proposal stopped applying while it waited. The store has
            // quarantined it and said why; move to whatever is next.
            closeIfQueueEmpty()

        case .needsAcknowledgment:
            // The action grew a risk since this card was drawn. The store has
            // replaced the verdict, so the sheet is about to show callouts the
            // user has not read: drop the ticks they made against the old one.
            acknowledged = []

        case .stale:
            // The click landed on a card that already left the queue. Nothing
            // happened; the sheet is about to redraw for whatever is next.
            closeIfQueueEmpty()
        }
    }

    private func closeIfQueueEmpty() {
        if store.pending.isEmpty { onClose() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.caiTextSecondary.opacity(0.4))

            Text(ActionReviewPresentation.emptyState)
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Routed through the delegate rather than `.caiShowSettings`: that
            // notification is only observed inside the action panel, which is
            // closed whenever this window was opened from the menu bar, so the
            // only button on the empty state would do nothing at all.
            Button(ActionReviewPresentation.emptyStateButton) {
                onOpenSettings()
                onClose()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
    }
}
