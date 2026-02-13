import Foundation

// MARK: - Action Models

struct ActionItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String  // SF Symbol name
    let shortcut: Int
    let type: ActionType
}

enum ActionType {
    case openURL(URL)
    case openMaps(String)
    case createCalendar(title: String, date: Date, location: String?, description: String? = nil)
    case search(String)
    case llmAction(LLMAction)
    case jsonPrettyPrint(String)
    case customPrompt
    case shortcutURL(String)  // URL template with %s placeholder
    case outputDestination(OutputDestination)  // Send text to external app/service
}

enum LLMAction {
    case summarize
    case translate(String)
    case define
    case explain
    case reply
    case proofread
    case custom(String)
}
