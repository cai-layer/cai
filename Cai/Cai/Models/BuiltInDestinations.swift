import CaiActionCore
import Foundation

/// Pre-defined output destinations for native macOS apps.
/// These work zero-config via AppleScript.
/// Fixed UUIDs ensure stable identity across launches.
struct BuiltInDestinations {

    static let email = OutputDestination(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Email",
        icon: "envelope.fill",
        type: .applescript(template: """
            tell application "Mail"
                set newMessage to make new outgoing message with properties {subject:"", content:"{{result}}"}
                set visible of newMessage to true
                activate
            end tell
            """),
        isEnabled: true,
        isBuiltIn: true,
        showInActionList: false
    )

    static let notes = OutputDestination(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Save to Notes",
        icon: "note.text",
        type: .applescript(template: """
            tell application "Notes"
                activate
                make new note with properties {body:"{{result}}"}
            end tell
            """),
        isEnabled: true,
        isBuiltIn: true,
        showInActionList: false
    )

    static let reminders = OutputDestination(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Create Reminder",
        icon: "checklist",
        type: .applescript(template: """
            tell application "Reminders"
                activate
                set myList to default list
                make new reminder at end of myList with properties {name:"{{result}}"}
            end tell
            """),
        isEnabled: false,
        isBuiltIn: true,
        showInActionList: false
    )

    /// Replaces the user's current selection in the source app by pasting the
    /// LLM result. Enabled by default and shown first (Cmd+1) because
    /// replace-in-place is the highest-leverage destination for most users.
    static let pasteBack = OutputDestination(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "Replace Selection",
        icon: "arrow.uturn.down.square",
        type: .pasteBack,
        isEnabled: true,
        isBuiltIn: true,
        showInActionList: false
    )

    /// Writes chain output to NSPasteboard so the user can paste / inspect via
    /// clipboard history after a multi-step chain finishes. Marked `chainOnly`
    /// so it only surfaces in chain editor autocomplete — outside chains, the
    /// "Enter on a result copies it" affordance already covers the same need.
    static let clipboard = OutputDestination(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        name: "Copy to Clipboard",
        icon: "doc.on.clipboard",
        type: .clipboardCopy,
        isEnabled: true,
        isBuiltIn: true,
        showInActionList: false,
        chainOnly: true
    )

    /// Terminates a chain by putting its output on screen in Cai. A no-op
    /// destination: `ResultRouting` reads it as "not consumed" and the run
    /// surface renders the text.
    ///
    /// `chainOnly` for the same reason as `clipboard` — it exists to give a
    /// chain a meaningful terminal step, and outside that context it would be
    /// noise: a "Show in Cai" chip in the result view would be a button that
    /// shows you what you are already looking at. It still appears in chain
    /// editor autocomplete and in the destinations an agent sees over MCP,
    /// which are the two places a chain actually gets terminated.
    ///
    /// Note it does NOT override `runInBackground`: a background action stays
    /// quiet and records its result even when it ends here.
    static let showInCai = OutputDestination(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        name: "Show in Cai",
        icon: "macwindow",
        type: .showInCai,
        isEnabled: true,
        isBuiltIn: true,
        showInActionList: false,
        chainOnly: true
    )

    /// All built-in destinations, seeded on first launch.
    /// Order matters — it drives Cmd+1, Cmd+2, … shortcuts in the result view.
    static let all: [OutputDestination] = [pasteBack, email, notes, reminders, clipboard, showInCai]
}
