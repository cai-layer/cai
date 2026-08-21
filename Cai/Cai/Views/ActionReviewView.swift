import AppKit
import CaiActionCore
import SwiftUI

/// The approval sheet: the one place an agent-authored action becomes real.
///
/// Three bands, top to bottom. A pinned header names the action (the name leads,
/// because it is the subject of the whole decision) with the create/update
/// prefix and provenance under it. A single scrolling body carries the evidence:
/// the payload (or, for an update, the diff) in monospace, never folded, plus
/// the resolved chain steps. A pinned control band holds the orange risk callout,
/// the acknowledgment, and the buttons, so the risk and the consent stay
/// co-visible with Approve however long the payload is: you cannot tick, scroll
/// away, and approve blind. The name is attacker-controlled, so it is sanitized
/// to one capped line before it is ever shown in Cai's own title voice.
///
/// One scroll, not three: the body scrolls, every block renders at its natural
/// height, and only chain-step directives fold (with an in-place "Show more"),
/// following the way GitHub and VS Code expand hunks in place while keeping the
/// actions in a fixed bar.
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

    /// Whether the user has acknowledged what the proposal on screen can do.
    /// Cleared whenever the card changes, so an acknowledgment is about one
    /// payload and is never inherited by the next.
    @State private var acknowledged = false

    /// False for a moment after the card changes. Approve owns the Return key
    /// and the queue advances in place, so without this a held or double
    /// Return carries straight into the next proposal, and a proposal
    /// arriving under the cursor can catch a click meant for the last one.
    @State private var isArmed = false

    /// Which proposal is on screen. Browsing is allowed; deciding is still one
    /// at a time. The acknowledgment is deliberately NOT kept per card: it is
    /// dropped on every card change, browsing away and back included, because
    /// a tick belongs to the payload that was on screen when it was made.
    @State private var browseIndex = 0

    /// Chain steps the reader has expanded past the collapsed line cap. Indices,
    /// not the steps themselves, and dropped on every card change so an
    /// expansion never carries a directive from one proposal onto the next.
    @State private var expandedSteps: Set<Int> = []

    /// Whether the reader has expanded a folded (long, riskless) prompt payload.
    /// Reset on every card change, like the acknowledgment and the steps.
    @State private var payloadExpanded = false

    private var proposal: PendingProposal? {
        guard !store.pending.isEmpty else { return nil }
        return store.pending[ActionReviewPresentation.clampedQueueIndex(browseIndex, count: store.pending.count)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let proposal {
                header(for: proposal)
                scrollBody(for: proposal)
                pinnedControls(for: proposal)
            } else {
                emptyState
            }
        }
        .frame(width: 540)
        .background(VisualEffectBackground(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Keyed on the whole proposal, not its id: a writer can rewrite the
        // same file in place, keeping the id while the payload changes. Ticks
        // (and expanded steps) belong to the bytes the user read, not to a
        // filename.
        .onChange(of: proposal) { _ in
            acknowledged = false
            expandedSteps = []
            payloadExpanded = false
        }
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
            // A cancelled sleep throws immediately. Arming anyway would hand
            // the card that replaced this one an instantly live Approve, and
            // stepping the queue cancels this task on every arrow press.
            guard (try? await Task.sleep(nanoseconds: 350_000_000)) != nil else { return }
            isArmed = true
        }
    }

    // MARK: - Header

    private func header(for proposal: PendingProposal) -> some View {
        let validated = proposal.validated
        let title = ActionReviewPresentation.windowTitle(
            name: validated.after.name, isUpdate: validated.isUpdate
        )

        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                // The name leads in the primary weight; the "New action" /
                // "Update" prefix is secondary, because which shape it is
                // matters less than what it is. One line, tail-truncated: the
                // name is sanitized and capped, but a long legitimate name
                // still must not wrap the header into the payload.
                //
                // No type chip here any more. "shell" beside a "Runs a shell
                // command" capability chip is the same fact in two chip
                // vocabularies 20pt apart — the noun sprawl the chips exist to
                // remove (design review, 2026-08-21). The type still leads the
                // payload's VoiceOver label, which is where it earns its keep;
                // `ActionReviewPresentation.typeChip` went with it rather than
                // lingering as dead copy no surface renders.
                (Text(title.prefix + " · ").foregroundColor(.caiTextSecondary)
                    + Text(title.name).foregroundColor(.caiTextPrimary))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(title.combined)

                // Provenance as the title's subtitle. Single line by
                // construction: the validator strips control characters and
                // caps the length, and this is the belt to that brace. A client
                // name is attacker-controlled text sitting in Cai's own voice.
                // The byline: who and when, dimmed a step below the summary so
                // the eye lands on what the action does, not who sent it.
                Text(ActionReviewPresentation.provenanceSubtitle(
                    client: proposal.provenance.client,
                    authoredAt: proposal.provenance.authoredAt,
                    now: Date()
                ))
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)

                // What the action will touch, in Cai's own voice, derived
                // only from the action itself by `CapabilityDetector`. This
                // replaced the prose mechanism line rather than joining it
                // (design review, option B): the header already carried name +
                // provenance, and a fourth claim restating the third is sprawl.
                // The prose survives as this row's VoiceOver string, so nothing
                // is lost to a screen reader.
                //
                // Chips say WHAT is touched, not in what order. The numbered
                // chain block in the scroll below is the ordered evidence and
                // must not be dropped on the grounds this row covers it.
                capabilityRow(for: validated.after)
                    .padding(.top, 2)
            }

            Spacer(minLength: 8)

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

    // MARK: - Capability chips

    /// What the action will touch, as small neutral capsules under the byline.
    ///
    /// Informational, never a warning. Gray capsules, no border, no hover, no
    /// indigo: per DESIGN.md a capsule is Cai stating a fact and a bordered
    /// rounded-rect is a control, which is what keeps these from reading like
    /// the editor's interactive `ChipToggle`s. Orange stays reserved for the
    /// escalation callout below, so a chip is never itself an alarm — a chip row
    /// that only appeared on dangerous actions would quietly become a second
    /// warning channel, and these appear on every action.
    ///
    /// The row lives in the pinned header rather than the scroll, so the glance
    /// cannot be scrolled away from Approve. It wraps and is never truncated
    /// here: eliding a capability on the approval surface is the under-detection
    /// this whole feature exists to avoid. Compact rows elsewhere may elide, and
    /// `Capability.sortOrder` guarantees the open-ended floor chip survives that.
    @ViewBuilder
    private func capabilityRow(for action: ActionSnapshot) -> some View {
        let capabilities = CapabilityDetector.capabilities(
            for: action, known: settings.knownActions
        )
        let engine = settings.aiEngine
        let summary = ActionReviewPresentation.actionSummary(
            type: action.type,
            steps: action.next,
            known: settings.knownActions,
            promptModel: action.type == .prompt ? settings.modelProvider.rawValue : nil
        )

        FlowLayout(spacing: 4) {
            ForEach(ActionReviewPresentation.chips(for: capabilities, engine: engine)) { chip in
                capabilityChip(chip)
            }

            // The row admitting its own limits. Plain text, not a chip: this is
            // not a capability, it is what Cai cannot promise. Wording is
            // derived from the cause, because exhaustiveness clears for shell,
            // Shortcuts and uninstalled steps alike.
            if let tail = ActionReviewPresentation.capabilityTail(for: capabilities) {
                Text(tail)
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.8))
                    .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element, one sentence: the prose line option B retired visually,
        // then what the chips say, then the row's limits.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActionReviewPresentation.capabilityAccessibilityLabel(
            summary: summary, capabilities: capabilities, engine: engine
        ))
    }

    private func capabilityChip(_ chip: ActionReviewPresentation.CapabilityChip) -> some View {
        HStack(spacing: 3) {
            Text(chip.label)
                .font(.system(size: 10, weight: .medium))

            // A secret name is the exact string typed inside `{{secrets.…}}`,
            // so it keeps the identifier treatment. Monospaced at the chip's own
            // size rather than at 12pt: DESIGN.md rule 4's substance is the
            // monospace, and type scales with its container the way radius does.
            // Truncates `.middle` with the full name in `.help()` — the
            // never-truncate rule governs which chips appear, not how wide one
            // identifier may grow.
            if let identifier = chip.identifier {
                Text(identifier)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundColor(.caiTextSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.caiSurface.opacity(0.8)))
        // A tooltip only where there is something to reveal: the full secret
        // name behind a `.middle` truncation. The row above owns the
        // accessibility element, so an individual chip never speaks.
        .modifier(OptionalHelp(text: chip.identifier))
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

    /// The one scroll on the sheet. Everything that is evidence lives here and
    /// renders at its natural height; only this region scrolls, and it is capped
    /// so a giant payload cannot size the window past the screen. The callout,
    /// the acknowledgment and the buttons deliberately do NOT live here: they
    /// are pinned below, so they stay on screen however far the reader scrolls.
    private func scrollBody(for proposal: PendingProposal) -> some View {
        let validated = proposal.validated

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // One frame, not two. A create shows its payload; an update
                // shows the diff, and the diff renders the whole action, so the
                // payload is always in it as context lines however small the
                // patch. Adding the payload block underneath would put the same
                // bytes on screen twice with nothing saying they are the same
                // bytes, leaving the user to decide which copy to trust.
                if let before = validated.before {
                    diffBlock(before: before, after: validated.after, changed: validated.changedFields)
                } else {
                    payloadBlock(
                        for: validated.after,
                        hasRisks: !validated.escalationReasons.isEmpty
                    )
                }

                if !validated.after.next.isEmpty {
                    chainBlock(for: validated.after)
                }

                if !validated.warnings.isEmpty {
                    warnings(validated.warnings)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Grow to fit the content, then cap and scroll. `fixedSize` makes the
        // ScrollView adopt its content's ideal height up to the frame's max,
        // the same trick the payload block used before it was unwrapped, so a
        // short proposal is a short sheet and a huge one scrolls inside a
        // bounded window.
        .frame(maxHeight: bodyMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The single body scroll's height ceiling, from the screen it is on.
    private var bodyMaxHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        return ActionReviewPresentation.bodyMaxHeight(screenHeight: screenHeight)
    }

    /// The pinned band under the scroll: the risk callout, the acknowledgment,
    /// and the buttons, in that reading order. Pinned so the risk and the
    /// consent are always visible with Approve, never scrolled away above a
    /// payload. A hairline marks it off from the scroll above.
    private func pinnedControls(for proposal: PendingProposal) -> some View {
        let validated = proposal.validated

        return VStack(alignment: .leading, spacing: 12) {
            callout(for: validated.escalationReasons, in: validated.after)

            if let label = ActionReviewPresentation.acknowledgment(for: validated.escalationReasons) {
                acknowledgmentRow(label)
            }

            footerButtons(for: proposal)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.caiDivider.opacity(0.5))
                .frame(height: 1)
        }
    }

    /// The hero. Monospace, carried by the single body scroll.
    ///
    /// Executable evidence (shell, url) never folds: the user has to be able to
    /// read every character that will run, and a fold is a place to hide the one
    /// line that matters. A long prompt may collapse for legibility, but only
    /// when it carries no risk; a risk-flagged prompt stays open so the callout's
    /// evidence is never behind a "Show more". `collapsedPayload` decides all of
    /// that, and VoiceOver reads the full value regardless of the visual fold.
    private func payloadBlock(for action: ActionSnapshot, hasRisks: Bool) -> some View {
        let fold = ActionReviewPresentation.collapsedPayload(
            type: action.type, value: action.value, hasRisks: hasRisks
        )
        let collapsed = fold != nil && !payloadExpanded

        return VStack(alignment: .leading, spacing: 8) {
            Text(action.value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.caiTextPrimary)
                .textSelection(.enabled)
                .lineLimit(collapsed ? fold?.lineLimit : nil)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let fold {
                Button(collapsed
                    ? ActionReviewPresentation.showMorePayload(totalLines: fold.totalLines)
                    : ActionReviewPresentation.showLessPayload
                ) {
                    payloadExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary)
                // Visual-only: the full value is on the accessibility element.
                .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                HStack(alignment: .top, spacing: 8) {
                    Text("\(step.index + 1)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.caiTextSecondary)
                        .frame(width: 14)

                    // Was capped at two lines with no way to read the rest, the
                    // one place this sheet clipped content. Now the directive
                    // caps at five lines and expands in place, so a long inline
                    // prompt is fully reachable without a per-step scrollbar.
                    ExpandableStepLabel(
                        text: step.label,
                        collapsedLineLimit: 5,
                        expanded: Binding(
                            get: { expandedSteps.contains(step.index) },
                            set: { isExpanded in
                                if isExpanded { expandedSteps.insert(step.index) }
                                else { expandedSteps.remove(step.index) }
                            }
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

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

            // Rendered at full height, carried by the single body scroll rather
            // than a scroller of its own: nothing about the change is collapsed
            // or hidden behind a fold on the one surface that must not be
            // misread.
            diffLines(
                before: ActionReviewPresentation.renderDocument(before),
                after: ActionReviewPresentation.renderDocument(after)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
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
    private func callout(for reasons: [EscalationReason], in action: ActionSnapshot) -> some View {
        // Names are scanned from the payload on screen at render time, never
        // read from the stored validation (CAI-25): what the callout claims is
        // exactly what the text the user is reading reaches for.
        switch ActionReviewPresentation.callout(
            for: reasons,
            secretNames: Array(SecretReference.names(in: action.value))
        ) {
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

    /// The habituation defense: one deliberate act, not one per risk. See
    /// `ActionReviewPresentation.canApprove` for why it is one and not zero.
    private func acknowledgmentRow(_ label: String) -> some View {
        Toggle(isOn: $acknowledged) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.caiTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Footer

    /// Reject and Approve, pinned below the scroll inside `pinnedControls`, so
    /// the decision is always on screen. No outer padding here: the pinned band
    /// owns the spacing.
    private func footerButtons(for proposal: PendingProposal) -> some View {
        let canApprove = isArmed && ActionReviewPresentation.canApprove(
            tier: proposal.validated.tier,
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
    }

    // MARK: - Actions

    private func approve(_ proposal: PendingProposal) {
        let isUpdate = proposal.validated.isUpdate

        // The store is handed the risks that were on screen, not a bare flag.
        // It re-validates at this moment, and if a new risk appeared since the
        // card was drawn it must not be covered by a tick the user gave to the
        // old set (CAI-25).
        let acknowledgedReasons: Set<EscalationReason> = acknowledged
            ? Set(proposal.validated.escalationReasons)
            : []

        switch store.approve(proposal, acknowledged: acknowledgedReasons) {
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
            // replaced the verdict, so the sheet is about to show a claim the
            // user has not read: drop the tick they gave the old one.
            acknowledged = false

        case .stale:
            // The click landed on a card that already left the queue. Nothing
            // happened; the sheet is about to redraw for whatever is next.
            closeIfQueueEmpty()

        case .reloaded:
            // The file changed under the card. The card stays, showing the
            // new bytes; without a toast the click reads as a dud and the
            // user's next click approves content they never re-read.
            acknowledged = false
            NotificationCenter.default.post(
                name: .caiShowToast,
                object: nil,
                userInfo: [
                    "message": ActionReviewPresentation.reloadedToast,
                    "icon": ToastQueue.Icon.warning.rawValue,
                ]
            )
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

/// A monospace label that caps at `collapsedLineLimit` lines and expands in
/// place, the way GitHub and VS Code reveal a clipped hunk. The "Show more"
/// control appears only when the text actually overflows the cap, measured
/// rather than guessed, so a step that fits shows no control and a step that
/// clips is never left with its tail hidden.
///
/// `expanded` is owned by the parent (a set of expanded indices), so it resets
/// when the card changes and an expansion never carries onto the next proposal.
private struct ExpandableStepLabel: View {
    let text: String
    let collapsedLineLimit: Int
    @Binding var expanded: Bool

    /// Height of the text laid out to the collapsed cap, and to its full
    /// extent, at the live width. `fixedSize` on each hidden probe decouples it
    /// from the height its parent proposes, so each GeometryReader reports the
    /// probe's own ideal height and the comparison is exact.
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > collapsedHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.caiTextPrimary)
                .lineLimit(expanded ? nil : collapsedLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(measurementProbes)
                .onPreferenceChange(CollapsedHeightKey.self) { collapsedHeight = $0 }
                .onPreferenceChange(FullHeightKey.self) { fullHeight = $0 }

            if isTruncated {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                    // Visual-only affordance: VoiceOver reads the full label
                    // from the combined step element regardless of the cap, so
                    // there is nothing here for it to reach.
                    .accessibilityHidden(true)
            }
        }
    }

    private var measurementProbes: some View {
        ZStack {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: CollapsedHeightKey.self, value: geo.size.height)
                })

            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: FullHeightKey.self, value: geo.size.height)
                })
        }
        .hidden()
    }
}

private struct CollapsedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
