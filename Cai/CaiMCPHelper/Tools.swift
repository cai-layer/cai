import CaiActionCore
import Foundation
import MCP

/// The three tools an agent gets. No delete, no run.
///
/// Agents author, humans fire. Nothing here can execute an action or remove
/// one, so the worst a compromised agent achieves is a proposal the user reads
/// and refuses.
///
/// The descriptions carry the authoring guidance deliberately: they are the
/// only documentation an agent reliably reads, so what makes a good Cai action
/// belongs in them rather than in a README nobody fetches.
enum Tools {

    static let all: [Tool] = [listActions, createAction, updateAction]

    // MARK: - list_actions

    static let listActions = Tool(
        name: "list_actions",
        description: """
            List the actions the user already has in Cai, plus the status of anything you have \
            proposed. Call this before authoring: an action that already does the job should be \
            updated rather than duplicated, and chain steps must refer to names that exist.

            There is no notification when the user approves or rejects something. Call this again \
            to find out: proposals appear as "waiting for approval" or "rejected by Cai" with the \
            reason.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    // MARK: - create_action

    static let createAction = Tool(
        name: "create_action",
        description: """
            Propose a new Cai action. It does not run and does not exist until the user approves \
            it in Cai; you cannot approve it yourself.

            An action runs on whatever the user has selected when they press Option+C.

            Types:
            - prompt: sends the selection plus your prompt text to the user's model. Write the \
            prompt as an instruction about "the selected text".
            - url: opens a URL. Use %s where the selection should be substituted, for example \
            https://www.google.com/search?q=%s
            - shell: runs a shell command. Use {{result}} where the selection should go; Cai \
            escapes it for you, so do not add quotes around it. Shell actions always require an \
            extra confirmation from the user, so keep them to one obvious job.

            Flags: autoReplaceSelection pastes the model's answer straight over the user's \
            selection (prompt actions only). runInBackground skips showing output (shell actions \
            only), which suits slow or fire-and-forget commands.

            next is an optional chain: each step receives the previous step's output as \
            {{result}}. A step is {"action": {"name": "..."}} for an existing Cai action or \
            destination, {"inlineLLM": {"directive": "..."}} for an ad-hoc model step, or \
            {"appleShortcut": {"name": "..."}} for a Shortcuts.app shortcut.

            Before writing something from scratch, check whether the community already has it: \
            https://github.com/cai-layer/cai-extensions has an index.json of ready-made actions.

            Keep names short and specific, under 60 characters, because the user types a few \
            letters of the name to find the action.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("name"), .string("type"), .string("value")]),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Short name the user will type to find this action. 1 to 60 characters."),
                ]),
                "type": .object([
                    "type": .string("string"),
                    "enum": .array([.string("prompt"), .string("url"), .string("shell")]),
                ]),
                "value": .object([
                    "type": .string("string"),
                    "description": .string("The prompt text, URL template with %s, or shell command with {{result}}."),
                ]),
                "autoReplaceSelection": .object([
                    "type": .string("boolean"),
                    "description": .string("Prompt actions only. Paste the answer over the selection without showing it first."),
                ]),
                "runInBackground": .object([
                    "type": .string("boolean"),
                    "description": .string("Shell actions only. Run without showing output."),
                ]),
                "pinned": .object([
                    "type": .string("boolean"),
                    "description": .string("Show this action at the top of the list."),
                ]),
                "next": .object([
                    "type": .string("array"),
                    "description": .string("Optional chain of steps to run after this action. Maximum 10."),
                    "items": .object(["type": .string("object")]),
                ]),
            ]),
        ])
    )

    // MARK: - update_action

    static let updateAction = Tool(
        name: "update_action",
        description: """
            Propose a change to an existing Cai action. Send only the fields you are changing. \
            The user sees the change as a diff and approves it before it takes effect.

            Get the id from list_actions, and call list_actions again first if your information \
            might be stale: if the user has edited the action since you read it, the update is \
            refused rather than applied, and you will need to read it again and re-propose.

            Changeable fields: name, type, value, autoReplaceSelection, runInBackground, pinned, next.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("id"), .string("changes")]),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Action id from list_actions."),
                ]),
                "changes": .object([
                    "type": .string("object"),
                    "description": .string("Only the fields to change, same shape as create_action."),
                ]),
            ]),
        ])
    )
}
