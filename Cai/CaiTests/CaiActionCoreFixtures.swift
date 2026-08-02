import Foundation
import CaiActionCore

/// Shared fixtures. Dates are fixed so encoded output is byte-comparable and
/// nothing in these tests depends on the clock.
enum CoreFixture {

    static let epoch = Date(timeIntervalSince1970: 0)
    static let changeId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let targetId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let otherId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    static let provenance = ActionProvenance(
        source: .mcp,
        client: "Claude Code",
        authoredAt: epoch
    )

    static func draft(
        name: String = "File issue",
        type: CaiActionType = .prompt,
        value: String = "Summarize this stack trace",
        autoReplaceSelection: Bool = false,
        runInBackground: Bool = false,
        pinned: Bool = false,
        next: [ChainStep] = []
    ) -> ActionDraft {
        ActionDraft(
            name: name,
            type: type,
            value: value,
            autoReplaceSelection: autoReplaceSelection,
            runInBackground: runInBackground,
            pinned: pinned,
            next: next
        )
    }

    static func change(
        _ operation: PendingChange.Operation,
        id: UUID = changeId,
        schemaVersion: Int = ActionSchema.version
    ) -> PendingChange {
        PendingChange(
            schemaVersion: schemaVersion,
            id: id,
            createdAt: epoch,
            provenance: provenance,
            operation: operation
        )
    }

    static func createChange(_ draft: ActionDraft = draft()) -> PendingChange {
        change(.create(draft))
    }

    static func updateChange(
        targetId: UUID = targetId,
        changes: ActionPatch,
        expected: ActionPatch
    ) -> PendingChange {
        change(.update(ActionUpdate(targetId: targetId, changes: changes, expected: expected)))
    }

    static func snapshot(
        id: UUID = targetId,
        name: String = "Existing action",
        type: CaiActionType = .prompt,
        value: String = "Rewrite this as a professional email",
        autoReplaceSelection: Bool = false,
        runInBackground: Bool = false,
        pinned: Bool = false,
        next: [ChainStep] = []
    ) -> ActionSnapshot {
        ActionSnapshot(
            id: id,
            name: name,
            type: type,
            value: value,
            autoReplaceSelection: autoReplaceSelection,
            runInBackground: runInBackground,
            pinned: pinned,
            next: next
        )
    }

    /// One installed prompt action plus the built-in destinations an action
    /// can chain into.
    static let known = KnownActions(
        shortcuts: [snapshot()],
        destinations: [
            DestinationSummary(name: "Notes", kind: .applescript),
            DestinationSummary(name: "Slack", kind: .webhook),
            DestinationSummary(name: "Open in Cursor", kind: .deeplink),
            DestinationSummary(name: "Run script", kind: .shell),
            DestinationSummary(name: "Replace Selection", kind: .pasteBack),
            DestinationSummary(name: "Copy to Clipboard", kind: .clipboardCopy),
        ],
        builtInActionNames: ["Summarize", "Explain"]
    )

    static func repeating(_ character: Character, _ count: Int) -> String {
        String(repeating: character, count: count)
    }
}
