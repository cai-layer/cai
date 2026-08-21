import Foundation

/// A proposal that passed validation, with everything the approval sheet and
/// the audit log need.
public struct ValidatedChange: Equatable, Sendable {
    public let changeId: UUID
    public let provenance: ActionProvenance
    /// The action as it exists today. `nil` for a create.
    public let before: ActionSnapshot?
    /// The action as it would exist after approval, normalized.
    public let after: ActionSnapshot
    /// Fields an update touches, in a stable order. Empty for a create.
    public let changedFields: [ActionField]
    public let warnings: [ActionWarning]
    public let tier: ApprovalTier
    public let escalationReasons: [EscalationReason]

    public var isUpdate: Bool { before != nil }

    /// Public so callers other than the validator can describe a verdict:
    /// tests of what the user and the agent are told, and the in-app authoring
    /// front-end when it arrives.
    public init(
        changeId: UUID,
        provenance: ActionProvenance,
        before: ActionSnapshot?,
        after: ActionSnapshot,
        changedFields: [ActionField],
        warnings: [ActionWarning],
        tier: ApprovalTier,
        escalationReasons: [EscalationReason]
    ) {
        self.changeId = changeId
        self.provenance = provenance
        self.before = before
        self.after = after
        self.changedFields = changedFields
        self.warnings = warnings
        self.tier = tier
        self.escalationReasons = escalationReasons
    }
}

/// The single source of trust for authored actions.
///
/// Compiled into both the app and the `cai-mcp` helper. The helper runs it
/// before writing a pending change so an agent gets an immediate, specific
/// error instead of silence; the app runs the same code again on the bytes it
/// reads off disk, because a helper is just a process on the user's Mac and
/// nothing that arrives through the pending directory is trusted.
///
/// Every function here is pure and nonisolated: no file IO, no singletons, no
/// clock. That is what makes the whole rejection matrix table-testable.
public enum ActionValidator {

    // MARK: - Entry point

    public static func validate(_ change: PendingChange, known: KnownActions) throws -> ValidatedChange {
        guard ActionSchema.supportedVersions.contains(change.schemaVersion) else {
            throw ActionRejection.unsupportedSchemaVersion(
                found: change.schemaVersion,
                supported: ActionSchema.version
            )
        }

        switch change.operation {
        case .create(let draft):
            return try validateCreate(draft, change: change, known: known)
        case .update(let update):
            return try validateUpdate(update, change: change, known: known)
        }
    }

    /// Whether one more proposal fits. Checked by the helper before it writes
    /// and by the app before it accepts, since either side can be the first to
    /// see the queue fill up.
    public static func hasRoomForAnotherChange(pendingCount: Int) -> Bool {
        pendingCount < ActionSchema.maxPendingChanges
    }

    // MARK: - Create

    private static func validateCreate(
        _ draft: ActionDraft,
        change: PendingChange,
        known: KnownActions
    ) throws -> ValidatedChange {
        // The proposal's own id becomes the action's id: it keeps the audit
        // line, the pending file and the stored action linkable, and it keeps
        // this function free of randomness. It must therefore be an id nothing
        // already answers to. Approving a create writes the action by id, so a
        // reused id would replace an existing action in place while the sheet
        // presented it as a new one: a "create" that quietly destroys the
        // user's shell action, with no diff and possibly no escalation.
        guard !known.shortcuts.contains(where: { $0.id == change.id }) else {
            throw ActionRejection.duplicateActionId(id: change.id.uuidString)
        }

        var warnings: [ActionWarning] = []
        let proposed = draft.snapshot(id: change.id)
        let normalized = try normalize(proposed, warnings: &warnings)

        warnings.append(contentsOf: nameWarnings(for: normalized, known: known))
        warnings.append(contentsOf: chainWarnings(for: normalized, known: known))
        warnings.append(contentsOf: flagWarnings(for: normalized))

        try validateURLScheme(normalized)

        let reasons = ApprovalClassifier.escalationReasons(for: normalized, known: known)
        return ValidatedChange(
            changeId: change.id,
            provenance: sanitized(change.provenance),
            before: nil,
            after: normalized,
            changedFields: [],
            warnings: warnings,
            tier: reasons.isEmpty ? .standard : .escalated,
            escalationReasons: reasons
        )
    }

    // MARK: - Update

    private static func validateUpdate(
        _ update: ActionUpdate,
        change: PendingChange,
        known: KnownActions
    ) throws -> ValidatedChange {
        guard let current = known.shortcuts.first(where: { $0.id == update.targetId }) else {
            throw ActionRejection.unknownTargetAction(id: update.targetId.uuidString)
        }
        guard !update.changes.isEmpty else {
            throw ActionRejection.emptyPatch
        }

        // Refuse to clobber. Every field the patch touches must carry the
        // value the helper read, and that value must still be what Cai holds:
        // the user may have edited the action between the agent's read and
        // this approval.
        for field in update.changes.fields {
            guard update.expected.contains(field) else {
                throw ActionRejection.missingExpectedValue(field: field.rawValue)
            }
            guard update.expected.matches(field, in: current) else {
                throw ActionRejection.valueMismatch(
                    field: field.rawValue,
                    expected: update.expected.rendered(field) ?? "",
                    current: current.rendered(field)
                )
            }
        }

        var warnings: [ActionWarning] = []
        let patched = update.changes.applied(to: current)
        let normalized = try normalize(patched, warnings: &warnings)

        // The scheme rule guards authored values, not pre-existing ones:
        // checked only when the patch writes the value or the type, so
        // pinning the user's own non-https action is not refused over a
        // value nobody proposed.
        if update.changes.fields.contains(.value) || update.changes.fields.contains(.type) {
            try validateURLScheme(normalized)
        }

        if normalized.name != current.name {
            warnings.append(contentsOf: nameWarnings(for: normalized, known: known))
        }
        warnings.append(contentsOf: chainWarnings(for: normalized, known: known))
        warnings.append(contentsOf: flagWarnings(for: normalized))
        warnings.append(contentsOf: update.changes.fields
            .filter { update.changes.matches($0, in: current) }
            .map { ActionWarning.noOpChange(field: $0) })

        let reasons = ApprovalClassifier.escalationReasons(for: normalized, known: known)
        return ValidatedChange(
            changeId: change.id,
            provenance: sanitized(change.provenance),
            before: current,
            after: normalized,
            changedFields: update.changes.fields,
            warnings: warnings,
            tier: reasons.isEmpty ? .standard : .escalated,
            escalationReasons: reasons
        )
    }

    // MARK: - Provenance

    /// Provenance labels are as attacker-controlled as the payload: the client
    /// name arrives in the same file, and the approval sheet renders it in
    /// Cai's own voice ("Proposed by ..."). Unsanitized, a name carrying
    /// newlines can add lines of reassuring copy above the payload, and a name
    /// carrying thousands of characters can push the Approve and Reject
    /// buttons off the bottom of the screen. Stripped and length-capped like a
    /// name, but deliberately not folded through
    /// `foldingInvisibleScalars()`: the fold exists so two names that render
    /// alike compare alike, and no duplicate comparison is made on a label.
    static func sanitized(_ provenance: ActionProvenance) -> ActionProvenance {
        ActionProvenance(
            source: provenance.source,
            client: sanitizedLabel(provenance.client),
            model: sanitizedLabel(provenance.model),
            authoredAt: provenance.authoredAt
        )
    }

    private static func sanitizedLabel(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .strippingControlCharacters(keepingNewlines: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(ActionSchema.maxProvenanceLabelLength))
    }

    // MARK: - Normalization and limits

    /// Cleans an action up the way the shortcuts editor would on save, then
    /// enforces the hard limits. Returns the cleaned action and appends a
    /// warning for anything it had to change, so the approval sheet can show
    /// the user that the payload was not passed through untouched.
    static func normalize(_ action: ActionSnapshot, warnings: inout [ActionWarning]) throws -> ActionSnapshot {
        var result = action

        let stripped = action.name
            .strippingControlCharacters(keepingNewlines: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped != action.name.trimmingCharacters(in: .whitespacesAndNewlines) {
            warnings.append(.controlCharactersRemoved(field: .name))
        }

        // The name the duplicate check compares must be the name the user
        // reads. Folded here rather than at comparison time so the stored
        // name is the folded one too: a comparison-only fold would leave the
        // invisible scalars in the action list, where the impersonation
        // actually pays off every time the user opens ⌥C.
        result.name = stripped.foldingInvisibleScalars()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.name != stripped {
            warnings.append(.invisibleCharactersNormalized(field: .name))
        }

        guard result.name.count >= ActionSchema.minNameLength else {
            throw ActionRejection.nameEmpty
        }
        guard result.name.count <= ActionSchema.maxNameLength else {
            throw ActionRejection.nameTooLong(max: ActionSchema.maxNameLength, found: result.name.count)
        }
        // After the grapheme cap, so a name that is long by both measures
        // reports the limit a human would recognize first.
        guard result.name.unicodeScalars.count <= ActionSchema.maxNameScalars else {
            throw ActionRejection.nameTooManyScalars(
                max: ActionSchema.maxNameScalars,
                found: result.name.unicodeScalars.count
            )
        }

        let strippedValue = action.value.strippingControlCharacters(keepingNewlines: true)
        if strippedValue != action.value {
            warnings.append(.controlCharactersRemoved(field: .value))
        }
        result.value = strippedValue.normalizingSmartQuotes().trimmingCharacters(in: .whitespacesAndNewlines)
        if result.value != strippedValue.trimmingCharacters(in: .whitespacesAndNewlines) {
            warnings.append(.smartQuotesNormalized(field: .value))
        }
        guard result.value.count >= ActionSchema.minValueLength else {
            throw ActionRejection.valueEmpty
        }
        guard result.value.count <= ActionSchema.maxValueLength else {
            throw ActionRejection.valueTooLong(max: ActionSchema.maxValueLength, found: result.value.count)
        }

        result.next = try normalizeChain(action.next, warnings: &warnings)
        return result
    }

    private static func normalizeChain(
        _ steps: [ChainStep],
        warnings: inout [ActionWarning]
    ) throws -> [ChainStep] {
        guard steps.count <= ActionSchema.maxChainSteps else {
            throw ActionRejection.chainTooLong(max: ActionSchema.maxChainSteps, found: steps.count)
        }

        var sanitized = false
        var result: [ChainStep] = []
        for (index, step) in steps.enumerated() {
            guard !step.isEmpty else {
                throw ActionRejection.chainStepEmpty(index: index)
            }
            // Names are matched against installed actions, so they follow the
            // name limit; an inline directive is a prompt and follows the
            // value limit.
            let cleaned: ChainStep
            let limit: Int
            switch step {
            case .action(let name):
                cleaned = .action(name: cleanStepText(name))
                limit = ActionSchema.maxNameLength
            case .appleShortcut(let name):
                cleaned = .appleShortcut(name: cleanStepText(name))
                limit = ActionSchema.maxNameLength
            case .inlineLLM(let directive):
                cleaned = .inlineLLM(directive: cleanStepText(directive))
                limit = ActionSchema.maxValueLength
            }
            if cleaned != step { sanitized = true }
            let length = cleaned.displayLabel.count
            guard length <= limit else {
                throw ActionRejection.chainStepTooLong(index: index, max: limit, found: length)
            }
            result.append(cleaned)
        }

        if sanitized {
            warnings.append(.controlCharactersRemoved(field: .next))
        }
        return result
    }

    private static func cleanStepText(_ text: String) -> String {
        text
            .strippingControlCharacters(keepingNewlines: false)
            .normalizingSmartQuotes()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Authored url actions are https-only, matching the webhook rule. This
    /// value is the one field a remote agent can turn into "open something on
    /// the user's Mac": a `file://` or app-scheme value launches rather than
    /// sends, which the approval callout ("sends your selected text to the
    /// URL") would misdescribe. The in-app editor is unrestricted; anything
    /// else is the user acting on their own machine.
    private static func validateURLScheme(_ action: ActionSnapshot) throws {
        guard action.type == .url, !action.value.lowercased().hasPrefix("https://") else { return }
        throw ActionRejection.urlActionMustUseHTTPS
    }

    // MARK: - Warnings

    private static func nameWarnings(for action: ActionSnapshot, known: KnownActions) -> [ActionWarning] {
        let clash = known.shortcuts.contains {
            $0.id != action.id && $0.name.caseInsensitiveCompare(action.name) == .orderedSame
        } || known.destinations.contains {
            $0.name.caseInsensitiveCompare(action.name) == .orderedSame
        }
        return clash ? [.duplicateName(action.name)] : []
    }

    private static func chainWarnings(for action: ActionSnapshot, known: KnownActions) -> [ActionWarning] {
        let unresolved = known.unresolvedChainStepNames(in: action.next)
        return unresolved.isEmpty ? [] : [.unresolvedChainSteps(unresolved)]
    }

    /// Flags the runtime ignores for the chosen type. Warned, not rejected:
    /// the action still does what its payload says, and refusing it would
    /// block an agent over a field that changes nothing.
    private static func flagWarnings(for action: ActionSnapshot) -> [ActionWarning] {
        var warnings: [ActionWarning] = []
        if action.autoReplaceSelection && action.type != .prompt {
            warnings.append(.flagIgnoredForType(flag: .autoReplaceSelection, type: action.type))
        }
        if action.runInBackground && action.type != .shell {
            warnings.append(.flagIgnoredForType(flag: .runInBackground, type: action.type))
        }
        return warnings
    }
}
