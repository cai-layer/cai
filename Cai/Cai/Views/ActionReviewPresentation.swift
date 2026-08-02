import CaiActionCore
import Foundation

/// Everything the approval sheet decides before it draws anything.
///
/// The sheet is the security boundary for agent authoring, so the parts that
/// determine what the user is told (which callout, which acknowledgment, what
/// the payload is, whether Approve can fire at all) are pure static functions
/// with a table-driven test each, not conditions buried in a view body. A
/// wrong callout here means a user approving something other than what they
/// read.
///
/// Copy strings come verbatim from the design specification in
/// `_docs/planning/active/MCP-AUTHORING-MLP-PLAN.md`.
enum ActionReviewPresentation {

    // MARK: - Fixed copy

    static let windowTitle = "Review proposed action"
    static let approveButton = "Approve"
    static let rejectButton = "Reject"
    static let emptyState = "No proposals waiting. Connect your agent in Settings to create actions from Claude Code."
    static let emptyStateButton = "Open Settings"
    /// Fallback when the MCP handshake carried no client name.
    static let unknownAuthor = "An agent"

    // MARK: - Escalation copy

    /// The plain-language warning shown under the payload, one per reason.
    static func callout(for reason: EscalationReason) -> String {
        switch reason {
        case .runsShellCommands:
            return "This action can run terminal commands on your Mac."
        case .sendsSelectionToURL:
            return "This action sends your selected text to the URL shown above."
        case .replacesSelection:
            return "This action replaces your selected text without showing a preview."
        case .runsWithoutShowingOutput:
            return "This action runs without showing its output."
        }
    }

    /// Lead-in for the grouped callout, used when an action carries more than
    /// one risk.
    static let calloutHeader = "This action will:"

    /// One risk as a list item, for the grouped callout. Same claim as the
    /// sentence form, minus the repeated "This action" that reads as noise
    /// once it is stacked three deep.
    static func calloutBullet(for reason: EscalationReason) -> String {
        switch reason {
        case .runsShellCommands:
            return "Run terminal commands on your Mac"
        case .sendsSelectionToURL:
            return "Send your selected text to the URL shown above"
        case .replacesSelection:
            return "Replace your selected text without showing a preview"
        case .runsWithoutShowingOutput:
            return "Run without showing its output"
        }
    }

    /// How the callout renders for a given set of risks: one sentence for a
    /// single risk (the design spec's verbatim copy), a grouped list beyond
    /// that.
    enum Callout: Equatable {
        case none
        case sentence(String)
        case grouped(header: String, bullets: [String])
    }

    static func callout(for reasons: [EscalationReason]) -> Callout {
        switch reasons.count {
        case 0:
            return .none
        case 1:
            return .sentence(callout(for: reasons[0]))
        default:
            return .grouped(header: calloutHeader, bullets: reasons.map(calloutBullet))
        }
    }

    /// The per-type acknowledgment that gates Approve. Deliberately the same
    /// claim as the callout in the first person: the habituation defense only
    /// works if checking the box means reading the sentence.
    static func acknowledgment(for reason: EscalationReason) -> String {
        switch reason {
        case .runsShellCommands:
            return "I understand this action can run terminal commands"
        case .sendsSelectionToURL:
            return "I understand this action sends my selected text to the URL shown above"
        case .replacesSelection:
            return "I understand this action replaces my selected text without showing a preview"
        case .runsWithoutShowingOutput:
            return "I understand this action runs without showing its output"
        }
    }

    // MARK: - The approve interlock

    /// Whether Approve can fire. On the escalated tier every reason shown must
    /// be acknowledged first, which is also what makes Return inert until the
    /// boxes are checked: the button owns the shortcut, so a disabled button
    /// swallows the key.
    static func canApprove(
        tier: ApprovalTier,
        reasons: [EscalationReason],
        acknowledged: Set<EscalationReason>
    ) -> Bool {
        guard tier == .escalated else { return true }
        return reasons.allSatisfy { acknowledged.contains($0) }
    }

    // MARK: - Queue

    /// "1 of 3" while more than one proposal waits, nil for a single one. The
    /// queue is deliberately one at a time; this only says how much is behind
    /// the current card.
    static func queueCounter(index: Int, total: Int) -> String? {
        guard total > 1 else { return nil }
        return "\(index + 1) of \(total)"
    }

    // MARK: - Toasts

    /// Arrival is passive: one toast, no window, no focus steal.
    static func arrivalToast(client: String?, isUpdate: Bool) -> String {
        let author = client ?? unknownAuthor
        return isUpdate
            ? "\(author) proposed a change to an action"
            : "\(author) proposed a new action"
    }

    static func approvedToast(isUpdate: Bool) -> String {
        isUpdate ? "Action updated" : "Action added"
    }

    /// Shown when a proposal stopped applying while it waited: the action it
    /// patches was edited or deleted, or its id is now taken. Distinct from
    /// the arrival copy, which would tell the user something just came in when
    /// what actually happened is that their own click was refused.
    static let refusedToast = "That proposal no longer applies. It was set aside and won't run."

    // MARK: - Provenance

    /// "Proposed by Claude Code · today 14:32". Time formatting follows the
    /// user's locale (12h or 24h); the day is relative because "when did this
    /// arrive" is the only question this line answers.
    static func provenanceLine(
        client: String?,
        authoredAt: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let time = formatter.string(from: authoredAt)

        let day: String
        if calendar.isDate(authoredAt, inSameDayAs: now) {
            day = "today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(authoredAt, inSameDayAs: yesterday) {
            day = "yesterday"
        } else {
            let dayFormatter = DateFormatter()
            dayFormatter.locale = locale
            dayFormatter.timeZone = timeZone
            dayFormatter.setLocalizedDateFormatFromTemplate("MMMd")
            day = dayFormatter.string(from: authoredAt)
        }

        return "Proposed by \(client ?? unknownAuthor) · \(day) \(time)"
    }

    /// The badge on an authored row in the shortcuts list, still answering
    /// "where did this come from" weeks later. `nil` for anything the user
    /// wrote themselves.
    static func provenanceBadge(for provenance: ActionProvenance?) -> String? {
        guard let provenance else { return nil }
        switch provenance.source {
        case .mcp:
            return "via \(provenance.client ?? unknownAuthor)"
        case .inApp:
            return "via Cai"
        }
    }

    // MARK: - Payload

    /// VoiceOver label for the payload block. The type has to be spoken: the
    /// difference between a prompt and a shell command is the whole decision.
    static func payloadLabel(for type: CaiActionType) -> String {
        switch type {
        case .prompt: return "Prompt this action will send"
        case .url: return "URL this action will open"
        case .shell: return "Shell command this action will run"
        }
    }

    // MARK: - Chain expansion

    /// One row per chain step, with referenced names resolved to what they
    /// actually are. A step reading "Slack" tells the user nothing; "Slack,
    /// webhook destination" tells them their selection leaves the Mac.
    struct ChainStepDisplay: Equatable, Identifiable {
        let index: Int
        let label: String
        let kind: String

        var id: Int { index }
    }

    static func chainSteps(_ steps: [ChainStep], known: KnownActions) -> [ChainStepDisplay] {
        steps.enumerated().map { index, step in
            ChainStepDisplay(index: index, label: step.displayLabel, kind: kind(of: step, known: known))
        }
    }

    private static func kind(of step: ChainStep, known: KnownActions) -> String {
        switch step {
        case .inlineLLM:
            return "Inline AI step"
        case .appleShortcut:
            return "Apple Shortcut"
        case .action(let name):
            switch known.resolveChainName(name) {
            case .shortcut(let shortcut):
                return "\(shortcut.type.label) action"
            case .destination(let destination):
                return "\(destinationLabel(destination.kind)) destination"
            case .builtIn:
                return "Built-in action"
            case .unresolved:
                return "Not installed"
            }
        }
    }

    private static func destinationLabel(_ kind: DestinationSummary.Kind) -> String {
        switch kind {
        case .applescript: return "AppleScript"
        case .webhook: return "Webhook"
        case .deeplink: return "Deeplink"
        case .shell: return "Shell"
        case .pasteBack: return "Replace Selection"
        case .clipboardCopy: return "Copy to Clipboard"
        }
    }

    // MARK: - Update diff

    /// One changed field, old value beside new. Only fields the patch touched
    /// appear, so the user reads the change rather than re-reading the action.
    struct DiffRow: Equatable, Identifiable {
        let field: ActionField
        let label: String
        let before: String
        let after: String

        var id: String { field.rawValue }
    }

    /// True when an update's diff rows alone would hide what actually runs.
    ///
    /// The diff shows only the fields the patch touched. A patch that flips
    /// execution semantics — `type: prompt → shell`, `runInBackground`,
    /// `autoReplaceSelection` — without touching `value` therefore renders a
    /// one-line diff and never the payload, and the user acknowledges "runs
    /// terminal commands" without being shown which command. Those updates
    /// render the full payload block beneath the diff. When the patch touches
    /// `value`, the diff already carries the whole new value as context lines
    /// and repeating it would make the user decide which copy to trust.
    static func updateShowsPayload(changed: [ActionField]) -> Bool {
        guard !changed.contains(.value) else { return false }
        return changed.contains { field in
            field == .type || field == .runInBackground || field == .autoReplaceSelection
        }
    }

    static func diffRows(before: ActionSnapshot, after: ActionSnapshot, changed: [ActionField]) -> [DiffRow] {
        changed.map { field in
            DiffRow(
                field: field,
                label: fieldLabel(field),
                before: before.rendered(field),
                after: after.rendered(field)
            )
        }
    }

    // MARK: - Line diff

    /// One rendered line of a unified diff, in the shape every developer
    /// already knows: old and new line numbers, a marker, tinted rows.
    struct DiffLine: Equatable, Identifiable {
        enum Kind: Equatable {
            case context
            case removed
            case added
        }

        let id: Int
        let kind: Kind
        let text: String
        /// Line number on the old side, absent for additions.
        let oldNumber: Int?
        /// Line number on the new side, absent for removals.
        let newNumber: Int?

        var marker: String {
            switch kind {
            case .context: return " "
            case .removed: return "−"
            case .added: return "+"
            }
        }
    }

    /// True when a field's change is worth a line diff rather than the compact
    /// old-above-new form. A one-word name change reads fine as two rows; a
    /// 30-line shell script where one line moved does not.
    static func needsLineDiff(before: String, after: String) -> Bool {
        before.contains("\n") || after.contains("\n")
    }

    /// A unified line diff over the whole value, nothing hidden.
    ///
    /// No collapsing: on an approval surface, "N unchanged lines" is a claim
    /// the user has to take on trust, and the whole point of this sheet is
    /// that nothing about the payload is taken on trust. The view scrolls
    /// instead.
    static func lineDiff(before: String, after: String) -> [DiffLine] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")

        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }

        // Walk both sides in step, emitting removals at their old offsets and
        // insertions at their new ones, numbering each side as it advances.
        var lines: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if let removed = removals[oldIndex] {
                lines.append(DiffLine(
                    id: lines.count, kind: .removed, text: removed,
                    oldNumber: oldIndex + 1, newNumber: nil
                ))
                oldIndex += 1
            } else if let inserted = insertions[newIndex] {
                lines.append(DiffLine(
                    id: lines.count, kind: .added, text: inserted,
                    oldNumber: nil, newNumber: newIndex + 1
                ))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                lines.append(DiffLine(
                    id: lines.count, kind: .context, text: old[oldIndex],
                    oldNumber: oldIndex + 1, newNumber: newIndex + 1
                ))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }

        return lines
    }

    static func fieldLabel(_ field: ActionField) -> String {
        switch field {
        case .name: return "Name"
        case .type: return "Type"
        case .value: return "Value"
        case .autoReplaceSelection: return "Replace selection"
        case .runInBackground: return "Run in background"
        case .pinned: return "Pinned"
        case .next: return "Chain"
        }
    }
}
