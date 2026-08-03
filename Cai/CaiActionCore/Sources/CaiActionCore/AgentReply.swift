import Foundation

/// What the agent reads back.
///
/// These strings are the entire interface an agent has to Cai's state, so they
/// are written to be acted on rather than displayed: ids it can pass back,
/// names a chain step can use, and the reason a proposal was refused phrased
/// as something to do about it. Tested for the same reason the approval sheet
/// copy is tested, one layer out.
public enum AgentReply {

    /// The answer to `list_actions`.
    public static func actionsListing(
        snapshot: ActionsSnapshot,
        statuses: [ProposalStatus]
    ) -> String {
        var lines: [String] = []

        if snapshot.actions.isEmpty {
            lines.append("The user has no custom actions yet.")
        } else {
            lines.append("Actions (\(snapshot.actions.count)):")
            for action in snapshot.actions {
                var detail = "- \(action.name) [\(action.type.rawValue)] id=\(action.id.uuidString)"
                if !action.next.isEmpty {
                    detail += " chain=\(ActionSnapshot.renderChain(action.next))"
                }
                lines.append(detail)
                lines.append("    \(singleLine(action.value))")
            }
        }

        if !snapshot.destinations.isEmpty {
            lines.append("")
            lines.append("Destinations a chain step can name: "
                + snapshot.destinations.map(\.name).joined(separator: ", "))
        }
        if !snapshot.builtInActionNames.isEmpty {
            lines.append("Built-in actions a chain step can name: "
                + snapshot.builtInActionNames.joined(separator: ", "))
        }

        lines.append("")
        if statuses.isEmpty {
            lines.append("No proposals of yours are waiting or rejected.")
        } else {
            lines.append("Your proposals:")
            for status in statuses {
                lines.append("- \(status.id): \(status.state.description)"
                    + (status.reason.map { " (\($0))" } ?? ""))
            }
        }

        if !snapshot.agentAuthoringEnabled {
            lines.append("")
            lines.append("Note: the user currently has agent proposals turned off, so new proposals will be refused.")
        }

        return lines.joined(separator: "\n")
    }

    /// The answer to a successful `create_action` or `update_action`.
    ///
    /// Says plainly that nothing has happened yet, because an agent that
    /// believes it has changed the user's setup will go on to act as if the
    /// action exists.
    public static func proposalAccepted(validated: ValidatedChange, actionName: String) -> String {
        var sentence: String
        if validated.isUpdate {
            let fields = validated.changedFields.map(\.rawValue).joined(separator: ", ")
            sentence = "Proposed a change to \"\(actionName)\" (\(fields))."
        } else {
            sentence = "Proposed \"\(actionName)\" to Cai."
        }

        sentence += validated.tier == .escalated
            ? " The user must acknowledge what it can do before they can approve it."
            : " It is waiting for the user to approve it in Cai."
        sentence += " Nothing happens until they do."

        if !validated.warnings.isEmpty {
            sentence += " Warnings shown to them: "
                + validated.warnings.map(\.summary).joined(separator: " ")
        }
        return sentence
    }

    /// The answer to `get_action`: one action, verbatim.
    ///
    /// Exists because the listing shortens values and `update_action` accepts
    /// a whole new one. Without a way to read the real thing, an agent asked
    /// to edit a long script rewrites the fragment it was shown and silently
    /// drops the rest; the guard that catches a user editing underneath it
    /// cannot catch this, because the helper captured `expected` from the full
    /// value the agent never saw.
    public static func actionDetail(_ action: ActionSnapshot) -> String {
        var lines = [
            "\(action.name) [\(action.type.rawValue)] id=\(action.id.uuidString)",
            "pinned=\(action.pinned) autoReplaceSelection=\(action.autoReplaceSelection)"
                + " runInBackground=\(action.runInBackground)",
        ]
        if !action.next.isEmpty {
            lines.append("chain=\(ActionSnapshot.renderChain(action.next))")
        }
        lines.append("")
        lines.append("value (\(action.value.count) characters, verbatim below this line):")
        lines.append(action.value)
        return lines.joined(separator: "\n")
    }

    /// One line per action for the listing, with the cut announced.
    ///
    /// Saying only "…" left an agent unable to tell a short value from a
    /// shortened one, so it would rewrite from the fragment believing it had
    /// the whole thing. The real length plus the name of the tool that returns
    /// it turns that into something it can act on.
    private static func singleLine(_ text: String, limit: Int = 100) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit))
            + "… [shortened; \(text.count) characters in full, call get_action before rewriting it]"
    }
}
