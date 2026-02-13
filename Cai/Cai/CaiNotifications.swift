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

    // Actions
    static let caiExecuteAction = NSNotification.Name("CaiExecuteAction")
    static let caiShowClipboardHistory = NSNotification.Name("CaiShowClipboardHistory")
    static let caiShowToast = NSNotification.Name("CaiShowToast")

    // System
    static let accessibilityPermissionChanged = NSNotification.Name("AccessibilityPermissionChanged")
}
