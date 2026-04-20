import Foundation

// MARK: - Action Models

struct ActionItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String  // SF Symbol name
    let shortcut: Int
    let type: ActionType
    /// Set by shortcut-driven actions where the user has opted in to
    /// auto-pasting the LLM response back over their selection.
    var autoReplaceSelection: Bool = false
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
    case shortcutShell(String)  // Shell command template with {{result}} placeholder
    case outputDestination(OutputDestination)  // Send text to external app/service
    case copyText  // Show extracted text in ResultView (used by "Show Extracted Text" from image OCR)
    case installExtension  // Install community extension from clipboard YAML
    case mcpAction(configId: String)  // MCP-powered action (e.g., "Create GitHub Issue")
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
