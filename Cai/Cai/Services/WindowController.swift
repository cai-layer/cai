import AppKit
import SwiftUI

// MARK: - CaiPanel

/// Custom NSPanel subclass that can become key window.
/// Standard NSPanel with .nonactivatingPanel returns NO from canBecomeKeyWindow,
/// which prevents keyboard events from being received. This override fixes that.
class CaiPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - SelectionState

/// Observable state holder so SwiftUI views react to selection changes
/// without recreating the entire hosting view.
class SelectionState: ObservableObject {
    @Published var selectedIndex: Int = 0
    @Published var filterText: String = ""
}

/// Manages the floating action window. Creates a borderless, translucent NSWindow
/// that hosts the SwiftUI ActionListWindow view. Handles positioning, keyboard
/// events (arrow keys, Enter, ESC, Cmd+1-9), and dismiss-on-click-outside.
class WindowController: NSObject, ObservableObject {
    /// When true, text-input keys (Return, arrows) pass through to the focused text field
    /// instead of being consumed by the keyboard handler. Set by views with text input.
    static var passThrough = false

    /// When true, printable keys update the filter text on selectionState.
    /// Set to true only when the action list screen is active.
    static var acceptsFilterInput = true
    private var window: NSWindow?
    private var toastWindow: NSWindow?
    private var actions: [ActionItem] = []
    private var currentText: String?
    private var selectionState = SelectionState()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var keyMonitor: Any?
    private var toastObserver: NSObjectProtocol?

    /// Resume support: keep the last-dismissed window alive briefly so
    /// reopening with the same clipboard text restores the exact view state.
    private var cachedWindow: NSWindow?
    private var cachedText: String?
    private var cachedPassThrough: Bool = false
    private var cachedDismissTime: Date?
    private var cacheCleanupTimer: Timer?
    private static let resumeTimeout: TimeInterval = 10

    /// Layout constants
    private static let windowWidth: CGFloat = 500
    private static let headerHeight: CGFloat = 52
    private static let footerHeight: CGFloat = 36
    private static let dividerHeight: CGFloat = 1
    private static let rowHeight: CGFloat = 46  // 7 + ~30 content + 7 padding + 2 spacing
    private static let listVerticalPadding: CGFloat = 16  // 6 top + 6 bottom + extra buffer
    private static let maxVisibleRows: CGFloat = 9  // matches ⌘1–9; scroll for the rest
    private static let cornerRadius: CGFloat = 20

    /// Minimum visible rows — keeps the window from looking cramped when there are few actions.
    private static let minVisibleRows: CGFloat = 4

    /// Calculates dynamic window height based on action count, clamped between 4 and 9 rows.
    private func calculateWindowHeight(actionCount: Int) -> CGFloat {
        let effectiveRows = min(max(CGFloat(actionCount), Self.minVisibleRows), Self.maxVisibleRows)
        let contentHeight = effectiveRows * Self.rowHeight + Self.listVerticalPadding
        return Self.headerHeight + Self.dividerHeight + contentHeight + Self.dividerHeight + Self.footerHeight
    }

    /// Shows the action window centered on screen with actions for the given content.
    func showActionWindow(text: String, detection: ContentResult, sourceApp: String? = nil) {
        // If window is already visible, dismiss first
        hideWindow()

        // Resume: if reopened with the same text within the timeout, restore the
        // previous window (preserving result view, custom prompt state, etc.)
        if let cached = cachedWindow,
           let cachedText = cachedText,
           let dismissTime = cachedDismissTime,
           cachedText == text,
           Date().timeIntervalSince(dismissTime) < Self.resumeTimeout {
            print("♻️ Resuming previous window (dismissed \(String(format: "%.1f", Date().timeIntervalSince(dismissTime)))s ago)")
            self.window = cached
            Self.passThrough = cachedPassThrough
            self.cachedWindow = nil
            self.cachedText = nil
            self.cachedPassThrough = false
            self.cachedDismissTime = nil
            cacheCleanupTimer?.invalidate()
            cacheCleanupTimer = nil

            cached.alphaValue = 0
            NSApp.activate(ignoringOtherApps: true)
            cached.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                cached.animator().alphaValue = 1
            }

            // Re-focus the content view so TextEditor regains keyboard input
            DispatchQueue.main.async {
                cached.makeFirstResponder(cached.contentView)
            }

            installEventMonitors()
            return
        }

        // Not resuming — clear any stale cache
        clearCache()

        let settings = CaiSettings.shared
        let actions = ActionGenerator.generateActions(
            for: text,
            detection: detection,
            settings: settings
        )
        self.actions = actions
        self.currentText = text

        // Reset selection state
        selectionState = SelectionState()

        // Calculate dynamic height
        let windowHeight = calculateWindowHeight(actionCount: actions.count)

        // Create dismiss/execute closures
        let dismissAction: () -> Void = { [weak self] in
            self?.hideWindow()
        }
        let executeAction: (ActionItem) -> Void = { [weak self] action in
            self?.executeSystemAction(action)
        }

        // Create the SwiftUI view with shared selection state
        let actionList = ActionListWindow(
            text: text,
            detection: detection,
            actions: actions,
            selectionState: selectionState,
            sourceApp: sourceApp,
            onDismiss: dismissAction,
            onExecute: executeAction
        )

        // Wrap in a hosting view (keyboard events are handled exclusively
        // by the keyMonitor local event monitor — no onKeyDown needed here
        // to avoid double-handling).
        let hostingView = KeyEventHostingView(
            rootView: actionList
                .frame(width: Self.windowWidth, height: windowHeight)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: windowHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = Self.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true

        // Create borderless CaiPanel (custom subclass that returns YES from canBecomeKey)
        let panel = CaiPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // We draw our own shadow in SwiftUI
        panel.level = .floating
        panel.isMovableByWindowBackground = true  // Drag to reposition
        panel.contentView = hostingView

        // Allow the panel to become key so we receive keyboard events
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        // Restore last saved position, or center on screen
        if let savedOrigin = Self.loadWindowPosition() {
            panel.setFrameOrigin(savedOrigin)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - Self.windowWidth / 2
            let y = screenFrame.midY - windowHeight / 2 + 50
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.window = panel

        // Activate our app temporarily so the panel can become key
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Fade in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        installEventMonitors()

        print("Action window shown with \(actions.count) actions (height: \(windowHeight))")
    }

    func hideWindow() {
        // Save window position before dismissing
        if let origin = window?.frame.origin {
            Self.saveWindowPosition(origin)
        }
        removeEventMonitors()

        // Cache the window for potential resume instead of destroying it.
        // The SwiftUI view hierarchy stays alive, preserving result/prompt state.
        if let window = window {
            window.alphaValue = 0
            window.orderOut(nil)

            // Replace any previous cache
            cachedWindow = window
            cachedText = currentText
            cachedPassThrough = Self.passThrough
            cachedDismissTime = Date()

            // Auto-destroy the cache after the resume timeout
            cacheCleanupTimer?.invalidate()
            cacheCleanupTimer = Timer.scheduledTimer(withTimeInterval: Self.resumeTimeout, repeats: false) { [weak self] _ in
                self?.clearCache()
            }
        }
        Self.passThrough = false
        Self.acceptsFilterInput = true
        window = nil
        currentText = nil
        actions = []
    }

    // MARK: - Event Monitors

    private func installEventMonitors() {
        // Monitor for clicks outside the window to dismiss (LOCAL events — within our app)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let window = self.window else { return event }
            let windowFrame = window.frame

            // Convert to screen coordinates
            if let eventWindow = event.window {
                let screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
                if !windowFrame.contains(screenPoint) {
                    self.hideWindow()
                }
            } else {
                if !windowFrame.contains(event.locationInWindow) {
                    self.hideWindow()
                }
            }
            return event
        }

        // Monitor for clicks outside the window to dismiss (GLOBAL events — other apps)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Global events always mean clicks outside our app
            self?.hideWindow()
        }

        // Monitor for key events — fires BEFORE the first responder chain,
        // so ESC works even when a TextField/TextEditor is focused.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window != nil else { return event }
            if self.handleKeyEvent(event) {
                return nil  // Consumed — suppress the event
            }
            return event  // Pass through to responder chain
        }

        // Listen for toast notifications from SwiftUI views
        toastObserver = NotificationCenter.default.addObserver(
            forName: .caiShowToast,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let message = notification.userInfo?["message"] as? String ?? "Copied to Clipboard"
            self?.showToast(message: message)
        }
    }

    private func removeEventMonitors() {
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let toastObserver = toastObserver {
            NotificationCenter.default.removeObserver(toastObserver)
            self.toastObserver = nil
        }
    }

    private func clearCache() {
        cachedWindow?.orderOut(nil)
        cachedWindow = nil
        cachedText = nil
        cachedDismissTime = nil
        cacheCleanupTimer?.invalidate()
        cacheCleanupTimer = nil
    }

    // MARK: - Position Persistence

    private static let positionXKey = "cai_windowPositionX"
    private static let positionYKey = "cai_windowPositionY"

    private static func saveWindowPosition(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: positionXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: positionYKey)
    }

    private static func loadWindowPosition() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: positionXKey) != nil else { return nil }
        let x = defaults.double(forKey: positionXKey)
        let y = defaults.double(forKey: positionYKey)
        // Validate the position is still on a connected screen
        let point = NSPoint(x: x, y: y)
        let testRect = NSRect(origin: point, size: NSSize(width: windowWidth, height: 100))
        for screen in NSScreen.screens {
            if screen.visibleFrame.intersects(testRect) {
                return point
            }
        }
        return nil  // Saved position is off-screen, reset to center
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Keyboard Handling

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // ESC — post a "back" notification; the SwiftUI view decides
        // whether to go back to action list or dismiss entirely.
        if event.keyCode == 53 {
            NotificationCenter.default.post(
                name: .caiEscPressed,
                object: nil
            )
            return true
        }

        // Cmd+Return — always captured (submit in custom prompt, or copy result)
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            NotificationCenter.default.post(
                name: .caiCmdEnterPressed,
                object: nil
            )
            return true
        }

        // When a text editor is active, let plain Return and arrows pass through
        // (Return adds newlines, arrows move cursor)
        if Self.passThrough {
            if event.keyCode == 126 || event.keyCode == 125 || event.keyCode == 36 {
                return false
            }
        }

        // Arrow Up
        if event.keyCode == 126 {
            NotificationCenter.default.post(
                name: .caiArrowUp,
                object: nil
            )
            return true
        }

        // Arrow Down
        if event.keyCode == 125 {
            NotificationCenter.default.post(
                name: .caiArrowDown,
                object: nil
            )
            return true
        }

        // Return/Enter
        if event.keyCode == 36 {
            NotificationCenter.default.post(
                name: .caiEnterPressed,
                object: nil
            )
            return true
        }

        // Cmd+0 — open clipboard history
        if event.modifierFlags.contains(.command) && event.keyCode == 29 {  // 29 = '0'
            NotificationCenter.default.post(
                name: .caiShowClipboardHistory,
                object: nil
            )
            return true
        }

        // Cmd+1 through Cmd+9
        if event.modifierFlags.contains(.command) {
            let keyNumber = keyCodeToNumber(event.keyCode)
            if let number = keyNumber, number >= 1 && number <= 9 {
                NotificationCenter.default.post(
                    name: .caiCmdNumber,
                    object: nil,
                    userInfo: ["number": number]
                )
                return true
            }
        }

        // Type-to-filter: capture printable characters and backspace
        // when not in a text input (passThrough) and no modifier keys held.
        if !Self.passThrough && Self.acceptsFilterInput && !event.modifierFlags.contains(.command) {
            // Backspace
            if event.keyCode == 51 {
                if !selectionState.filterText.isEmpty {
                    selectionState.filterText.removeLast()
                    selectionState.selectedIndex = 0
                }
                return true
            }

            // Printable characters
            let significantFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasOnlyShift = significantFlags.subtracting(.shift).isEmpty
            if hasOnlyShift,
               let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
               chars.rangeOfCharacter(from: .controlCharacters) == nil {
                let typed = event.characters ?? chars
                selectionState.filterText.append(typed)
                selectionState.selectedIndex = 0
                return true
            }
        }

        return false
    }

    private func keyCodeToNumber(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1  // 1
        case 19: return 2  // 2
        case 20: return 3  // 3
        case 21: return 4  // 4
        case 23: return 5  // 5
        case 22: return 6  // 6
        case 26: return 7  // 7
        case 28: return 8  // 8
        case 25: return 9  // 9
        default: return nil
        }
    }

    // MARK: - System Actions

    private func executeSystemAction(_ action: ActionItem) {
        switch action.type {
        case .openURL(let url):
            SystemActions.openURL(url)
            hideWindow()

        case .openMaps(let address):
            SystemActions.openInMaps(address)
            hideWindow()

        case .search(let query):
            SystemActions.searchWeb(query, searchBaseURL: CaiSettings.shared.searchURL)
            hideWindow()

        case .createCalendar(let title, let date, let location, let description):
            SystemActions.createCalendarEvent(title: title, date: date, location: location, description: description)
            hideWindow()

        default:
            // LLM actions, JSON pretty print, custom prompt are handled by ActionListWindow
            break
        }
    }

    // MARK: - Toast Notification

    /// Shows a pill-shaped toast notification that auto-dismisses after 1.5 seconds.
    func showToast(message: String) {
        hideToast()

        let toastView = ToastView(message: message)
        let hostingView = NSHostingView(rootView: toastView)
        hostingView.wantsLayer = true

        // Size the hosting view to fit content
        let fittingSize = hostingView.fittingSize
        let width = max(fittingSize.width, 200)
        let height = max(fittingSize.height, 36)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView
        panel.ignoresMouseEvents = true

        // Position at top-center of screen
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - width / 2
            let y = screenFrame.maxY - 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.toastWindow = panel
        panel.alphaValue = 0
        panel.orderFront(nil)

        // Fade in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }

        // Auto-dismiss after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.hideToast()
        }
    }

    private func hideToast() {
        guard let toast = toastWindow else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            toast.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.toastWindow?.orderOut(nil)
            self?.toastWindow = nil
        })
    }
}

// MARK: - KeyEventHostingView

/// Custom NSHostingView that accepts first responder so the window can
/// become key. Keyboard events are handled exclusively by the keyMonitor
/// (local event monitor) installed in WindowController.installEventMonitors(),
/// so no keyDown override is needed here.
class KeyEventHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure we become first responder so the panel stays key
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
}
