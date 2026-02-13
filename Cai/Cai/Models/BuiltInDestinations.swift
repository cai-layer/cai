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
                make new note at folder "Notes" with properties {body:"{{result}}"}
            end tell
            """),
        isEnabled: true,
        isBuiltIn: true,
        showInActionList: true
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

    /// All built-in destinations, seeded on first launch
    static let all: [OutputDestination] = [email, notes, reminders]
}
