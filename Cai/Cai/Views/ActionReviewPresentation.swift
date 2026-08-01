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
