import Foundation

/// Why a proposal cannot become an action.
///
/// Every case carries enough detail for the agent to fix the proposal in one
/// retry (the single-retry pattern from ACTION-BUILDER-HELPER-SPEC). The same
/// `reason` string is what the app writes to the audit log when it quarantines
/// a file and what `list_actions` reports back, so an agent can always tell
/// the user why nothing appeared in Cai.
public enum ActionRejection: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case unknownField(String)
    case malformedJSON(String)
    case nameEmpty
    case nameTooLong(max: Int, found: Int)
    case valueEmpty
    case valueTooLong(max: Int, found: Int)
    case chainTooLong(max: Int, found: Int)
    case chainStepEmpty(index: Int)
    case chainStepTooLong(index: Int, max: Int, found: Int)
    case queueFull(max: Int)
    case duplicateActionId(id: String)
    case unknownTargetAction(id: String)
    case emptyPatch
    case missingExpectedValue(field: String)
    case valueMismatch(field: String, expected: String, current: String)
    case urlActionMustUseHTTPS

    /// Plain-language explanation, safe to hand straight to an agent or to
    /// write into the audit log.
    public var reason: String {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return "Unsupported schema version \(found). This copy of Cai understands version \(supported)."
        case .unknownField(let field):
            return "Unknown field '\(field)'. Remove it and send the proposal again."
        case .malformedJSON(let detail):
            return "The proposal is not a valid Cai action: \(detail)"
        case .nameEmpty:
            return "The action name is empty."
        case .nameTooLong(let max, let found):
            return "The action name is \(found) characters. The limit is \(max)."
        case .valueEmpty:
            return "The action value is empty."
        case .valueTooLong(let max, let found):
            return "The action value is \(found) characters. The limit is \(max)."
        case .chainTooLong(let max, let found):
            return "The chain has \(found) steps. The limit is \(max)."
        case .chainStepEmpty(let index):
            return "Chain step \(index + 1) is empty."
        case .chainStepTooLong(let index, let max, let found):
            return "Chain step \(index + 1) is \(found) characters. The limit is \(max)."
        case .queueFull(let max):
            return "Cai already has \(max) proposals waiting for review. Ask the user to approve or reject some before sending more."
        case .duplicateActionId(let id):
            return "An action with id \(id) already exists. Send an update_action to change it, or let Cai assign a new id."
        case .unknownTargetAction(let id):
            return "No action with id \(id) exists in Cai. Call list_actions for the current ids."
        case .emptyPatch:
            return "The update carries no changes."
        case .missingExpectedValue(let field):
            return "The update changes '\(field)' without saying which value it expected to find there."
        case .valueMismatch(let field, let expected, let current):
            let (expectedExcerpt, currentExcerpt) = Self.excerptsAroundDifference(expected, current)
            return "'\(field)' changed in Cai after this update was prepared, so it was not applied. "
                + "Expected \(expectedExcerpt) but found \(currentExcerpt). "
                + "Read the action again and send a fresh update."
        case .urlActionMustUseHTTPS:
            return "URL actions must use https. For anything else, ask the user to create the action in Cai's shortcut editor."
        }
    }

    /// Short quoted excerpt for mismatch messages. Full values stay in the
    /// structured case; only the prose is clipped, so a 10K prompt doesn't
    /// turn one rejection into a wall of text for the agent.
    static func excerpt(_ text: String, limit: Int = 120) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= limit { return "\"\(collapsed)\"" }
        return "\"\(collapsed.prefix(limit))…\""
    }

    /// A pair of excerpts positioned so the difference is actually visible.
    ///
    /// Clipping both values from the start is useless when they share a long
    /// prefix, which two versions of the same script almost always do: the
    /// message then reads "expected X but found X" with two identical strings,
    /// and the agent has nothing to correct against. Both windows are centered
    /// on the first character that differs instead.
    static func excerptsAroundDifference(
        _ expected: String,
        _ current: String,
        width: Int = 120
    ) -> (String, String) {
        let left = expected.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let right = current.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        let divergence = zip(left, right).prefix(while: { $0 == $1 }).count
        // Back up a little so the difference has context in front of it.
        let start = max(0, divergence - width / 3)

        return (excerptWindow(into: left, from: start, length: width),
                excerptWindow(into: right, from: start, length: width))
    }

    private static func excerptWindow(into text: String, from start: Int, length: Int) -> String {
        guard start < text.count else {
            return text.isEmpty ? "\"\"" : "\"…\""
        }
        let begin = text.index(text.startIndex, offsetBy: start)
        let end = text.index(begin, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        let leading = start > 0 ? "…" : ""
        let trailing = end < text.endIndex ? "…" : ""
        return "\"\(leading)\(text[begin..<end])\(trailing)\""
    }
}

/// Something worth telling the user on the approval sheet, but not worth
/// refusing the proposal over.
public enum ActionWarning: Equatable, Sendable {
    /// Another installed action already answers to this name.
    case duplicateName(String)
    case controlCharactersRemoved(field: ActionField)
    case smartQuotesNormalized(field: ActionField)
    /// Chain steps that don't resolve to anything installed on this Mac; the
    /// action will fail at that step until the user installs them.
    case unresolvedChainSteps([String])
    /// A flag the runtime ignores for this action type (for example
    /// `runInBackground` on a prompt action).
    case flagIgnoredForType(flag: ActionField, type: CaiActionType)
    /// A patched field whose new value equals the current one.
    case noOpChange(field: ActionField)

    public var summary: String {
        switch self {
        case .duplicateName(let name):
            return "Another action is already named \"\(name)\"."
        case .controlCharactersRemoved(let field):
            return "Hidden control characters were removed from \(field.rawValue)."
        case .smartQuotesNormalized(let field):
            return "Curly quotes in \(field.rawValue) were replaced with straight quotes."
        case .unresolvedChainSteps(let names):
            return "Chain needs: \(names.joined(separator: ", "))."
        case .flagIgnoredForType(let flag, let type):
            return "\(flag.rawValue) has no effect on a \(type.rawValue) action."
        case .noOpChange(let field):
            return "\(field.rawValue) is already set to the proposed value."
        }
    }
}
