import CaiActionCore
import Foundation

// MARK: - Action Models

struct ActionItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String  // SF Symbol name
    /// Display-only ⌘ keyboard number (1-9). `var` so filter-to-reveal can
    /// renumber an existing item via in-place mutation rather than rebuilding,
    /// which historically dropped newer fields (`next`, `runInBackground`)
    /// because the rebuild had to be kept exhaustively in sync by hand.
    var shortcut: Int
    let type: ActionType
    /// Set by shortcut-driven actions where the user has opted in to
    /// auto-pasting the LLM response back over their selection.
    var autoReplaceSelection: Bool = false
    /// Chain steps to run after this action completes. Snapshot of the
    /// source `CaiShortcut.next` / `OutputDestination.next` taken at action
    /// generation time. Empty means no chain. When non-empty, dispatch
    /// forces the background path so `ChainExecutor` can run silently with
    /// menu-bar pulse + terminal toast UX.
    var next: [ChainStep] = []
    /// Used by `.prompt`-type shortcuts to opt into silent background dispatch
    /// (dismiss Cai immediately, run the LLM call off-screen, surface result as
    /// a toast). Shell shortcuts carry the same flag inline on the
    /// `.shortcutShell` enum case; this field is for the prompt path.
    var runInBackground: Bool = false
    /// What this action touches, for the row subtitle. Only custom actions
    /// carry them: built-ins have Cai's own hand-written subtitles, which are
    /// already plain-language statements of purpose and better than a chip row
    /// would be. Derived at generation time by `CapabilityDetector`, which is
    /// also when the action list is built, so it is a live read.
    var capabilities: [Capability] = []
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
    case shortcutShell(command: String, runInBackground: Bool)  // Shell command template; runInBackground dismisses Cai + toasts on completion
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
