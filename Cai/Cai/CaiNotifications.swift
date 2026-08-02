import Foundation

extension NSNotification.Name {
    // Keyboard events (posted by WindowController, observed by views)
    static let caiEscPressed = NSNotification.Name("CaiEscPressed")
    static let caiEnterPressed = NSNotification.Name("CaiEnterPressed")
    static let caiCmdEnterPressed = NSNotification.Name("CaiCmdEnterPressed")
    static let caiArrowUp = NSNotification.Name("CaiArrowUp")
    static let caiArrowDown = NSNotification.Name("CaiArrowDown")
    static let caiCmdNumber = NSNotification.Name("CaiCmdNumber")
    static let caiTabPressed = NSNotification.Name("CaiTabPressed")
    static let caiCmdNPressed = NSNotification.Name("CaiCmdNPressed")
    static let caiFilterCharacter = NSNotification.Name("CaiFilterCharacter")   // userInfo["char": String]
    static let caiFilterBackspace = NSNotification.Name("CaiFilterBackspace")

    // Actions
    static let caiExecuteAction = NSNotification.Name("CaiExecuteAction")
    static let caiShowClipboardHistory = NSNotification.Name("CaiShowClipboardHistory")
    static let caiShowToast = NSNotification.Name("CaiShowToast")
    /// Posted by `CaiSettings` whenever a property that affects action generation
    /// changes (shortcuts, hidden built-ins, output destinations, translation language).
    /// Observed by `WindowController` (clears the resume cache) and by
    /// `ActionListWindow` (regenerates its `actions` so an open list stays live).
    static let caiInvalidateActionCache = NSNotification.Name("CaiInvalidateActionCache")

    // System
    static let accessibilityPermissionChanged = NSNotification.Name("AccessibilityPermissionChanged")
    static let caiShowModelSetup = NSNotification.Name("CaiShowModelSetup")
    static let caiHotKeyChanged = NSNotification.Name("CaiHotKeyChanged")
    static let caiShowSettings = NSNotification.Name("CaiShowSettings")
    static let caiResetWindowSize = NSNotification.Name("CaiResetWindowSize")

    // MCP
    static let caiMCPStatusChanged = NSNotification.Name("CaiMCPStatusChanged")  // userInfo["configId": UUID]
    /// Posted by `PendingChangeStore` whenever the approval queue gains or
    /// loses a proposal. Drives the menu-bar dot and the review window's
    /// "1 of N" title.
    static let caiPendingChangesChanged = NSNotification.Name("CaiPendingChangesChanged")
    /// Posted by the action list's notice banner to open the approval sheet.
    /// Observed by `AppDelegate`, which owns that window.
    static let caiShowActionReview = NSNotification.Name("CaiShowActionReview")
    static let caiMCPFormSubmit = NSNotification.Name("CaiMCPFormSubmit")         // Triggers form submission
}
