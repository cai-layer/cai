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

    /// True when the active floating-window screen submits via the central key
    /// monitor on a bare Return — the Ask AI box, the result follow-up, and the
    /// MCP connector form. Combined with the global `pressReturnToSend` setting,
    /// a bare Return submits instead of inserting a newline. Form editors built on
    /// `MultilineTextEditor` (Destinations / Shortcuts / inline edit) honor the same
    /// setting through `ForwardingTextView` rather than this flag.
    static var submitScreenActive = false
    private var window: NSWindow?
    private var toastWindow: NSWindow?
    private var actions: [ActionItem] = []
    private var currentText: String?
    private var selectionState = SelectionState()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var keyMonitor: Any?
    private var toastObserver: NSObjectProtocol?
    /// Messages waiting for the pill. See `ToastQueue`.
    private var toastQueue = ToastQueue()
    /// The message on screen right now, or nil when the slot is free.
    private var showingToastMessage: String?

    /// Resume support: keep the last-dismissed window alive briefly so
    /// reopening with the same clipboard text restores the exact view state.
    private var cachedWindow: NSWindow?
    private var cachedText: String?
    private var cachedPassThrough: Bool = false
    private var cachedSubmitScreenActive: Bool = false
    private var cachedDismissTime: Date?
    private var cacheCleanupTimer: Timer?
    private static let resumeTimeout: TimeInterval = 7

    /// Layout constants
    private static let windowWidth: CGFloat = 540
    private static let headerHeight: CGFloat = 52
    private static let footerHeight: CGFloat = 36
    private static let dividerHeight: CGFloat = 1
    private static let rowHeight: CGFloat = 46  // 7 + ~30 content + 7 padding + 2 spacing
    private static let listVerticalPadding: CGFloat = 16  // 6 top + 6 bottom + extra buffer
    private static let maxVisibleRows: CGFloat = 6  // compact like Spotlight/Raycast; scroll for the rest
    private static let cornerRadius: CGFloat = 20

    override init() {
        super.init()
        // Toast observer is permanent — NOT tied to event monitors.
        // This allows toasts to show after hideWindow() removes event monitors.
        toastObserver = NotificationCenter.default.addObserver(
            forName: .caiShowToast,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let message = notification.userInfo?["message"] as? String ?? "Copied to Clipboard"

            // A TCC-denied action failure (e.g. "No Calendar access … (-2700)")
            // is something the user can actually fix — so instead of flashing a
            // raw error toast, offer to grant it inside Cai (the in-process
            // prompt we verified works). `offerGrantIfPossible` returns false for
            // every non-TCC message, so this is a no-op for ordinary toasts.
            // This observer runs on the main queue, so `assumeIsolated` is safe.
            let handledByGrantOffer = MainActor.assumeIsolated {
                NativeAccessManager.shared.offerGrantIfPossible(forErrorMessage: message)
            }
            if handledByGrantOffer { return }

            let icon = (notification.userInfo?["icon"] as? String).flatMap(ToastQueue.Icon.init(rawValue:)) ?? .success
            if let duration = notification.userInfo?["duration"] as? TimeInterval {
                self?.showToast(message: message, duration: duration, icon: icon)
            } else {
                self?.showToast(message: message, icon: icon)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .caiResetWindowSize,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetCurrentWindowSize()
        }
        // Drop the resume cache when settings that affect action generation
        // change. Without this, ⌥C within `resumeTimeout` after a settings
        // toggle restores the stale window with stale actions.
        NotificationCenter.default.addObserver(
            forName: .caiInvalidateActionCache,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearCache()
        }
        // A foreground chain finished on "Show in Cai". Chains dismiss the panel
        // at trigger, so there is usually no window left to navigate — bring one
        // up, then re-post so the freshly mounted view lands on the run surface.
        NotificationCenter.default.addObserver(
            forName: .caiShowRunResult,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // A re-post carries the token, so it is never trampolined again —
            // belt and braces against a `showActionWindow` that somehow leaves
            // the window not visible, which would otherwise self-post forever.
            guard notification.userInfo?[Self.runResultRepostKey] == nil else { return }
            MainActor.assumeIsolated { self?.showRunResultWindow() }
        }
    }

    /// Brings the panel up on the finished run's result.
    ///
    /// A visible window needs nothing from here: `ActionListWindow` observes the
    /// same notification and navigates itself. Only the dismissed case has work
    /// to do, and the re-post is what drives navigation there — it arrives once
    /// the window exists, and this observer no-ops on it because the window is
    /// visible by then, so there is no loop.
    private func showRunResultWindow() {
        // `hideWindow` nils `window` while parking the live hierarchy in
        // `cachedWindow`, so this guard is not fooled by the resume cache.
        guard !isVisible else { return }
        let emptyDetection = ContentResult(type: .shortText, confidence: 0.0, entities: ContentEntities())
        showActionWindow(text: "", detection: emptyDetection)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .caiShowRunResult,
                object: nil,
                userInfo: [Self.runResultRepostKey: true]
            )
        }
    }

    /// Marks the re-post fired by `showRunResultWindow`, so it drives the view's
    /// navigation without re-entering this controller's own observer.
    private static let runResultRepostKey = "caiRunResultRepost"

    /// Clears saved window dimensions and animates the current window (if visible)
    /// back to the default Spotlight footprint. Invoked by Settings → General.
    private func resetCurrentWindowSize() {
        Self.resetWindowSize()
        guard let window = window else { return }
        let newSize = NSSize(width: Self.windowWidth, height: Self.fixedWindowHeight)
        var frame = window.frame
        // Keep the window centered on its current origin so it doesn't jump visually.
        let oldCenter = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = newSize
        frame.origin = NSPoint(x: oldCenter.x - newSize.width / 2, y: oldCenter.y - newSize.height / 2)
        window.setFrame(frame, display: true, animate: true)
    }

    deinit {
        if let toastObserver = toastObserver {
            NotificationCenter.default.removeObserver(toastObserver)
        }
    }

    /// Default / minimum window height. Sized to show `maxVisibleRows` rows (Spotlight-style).
    /// The window is vertically resizable: users can drag the bottom edge to grow it,
    /// useful for the Settings screens and long result bodies. Width stays pinned.
    private static var fixedWindowHeight: CGFloat {
        let contentHeight = maxVisibleRows * rowHeight + listVerticalPadding
        return headerHeight + dividerHeight + contentHeight + dividerHeight + footerHeight
    }

    private static let widthKey = "cai_windowWidth"
    private static let heightKey = "cai_windowHeight"

    private static func saveWindowSize(_ size: NSSize) {
        UserDefaults.standard.set(Double(size.width), forKey: widthKey)
        UserDefaults.standard.set(Double(size.height), forKey: heightKey)
    }

    private static func loadWindowSize() -> NSSize? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: widthKey) != nil || defaults.object(forKey: heightKey) != nil else { return nil }
        let width = defaults.object(forKey: widthKey) != nil
            ? max(CGFloat(defaults.double(forKey: widthKey)), windowWidth)
            : windowWidth
        let height = defaults.object(forKey: heightKey) != nil
            ? max(CGFloat(defaults.double(forKey: heightKey)), fixedWindowHeight)
            : fixedWindowHeight
        return NSSize(width: width, height: height)
    }

    /// Clears any persisted window size so the next open returns to defaults.
    /// Invoked by the Settings → General "Reset window size" button.
    static func resetWindowSize() {
        UserDefaults.standard.removeObject(forKey: widthKey)
        UserDefaults.standard.removeObject(forKey: heightKey)
    }

    /// Shows the action window in settings mode (triggered by menu bar left-click).
    func showSettingsWindow() {
        if isVisible {
            // Window already showing — toggle: navigate to settings or dismiss
            NotificationCenter.default.post(name: .caiShowSettings, object: nil)
            return
        }
        // Not visible — create a new window in settings mode
        clearCache()
        let emptyDetection = ContentResult(type: .shortText, confidence: 0.0, entities: ContentEntities())
        showActionWindow(text: "", detection: emptyDetection, showSettings: true)
    }

    /// Shows the action window centered on screen with actions for the given content.
    ///
    /// `sourceApp` is the frontmost app's display name (used in LLM prompts as context hint).
    /// `sourceBundleId` is the canonical bundle ID (used by `ContextSnippetsManager` to
    /// match per-app context snippets — see https://getcai.app/docs/usage/context-snippets/).
    func showActionWindow(text: String, detection: ContentResult, sourceApp: String? = nil, sourceBundleId: String? = nil, showSettings: Bool = false) {
        // If a Context Snippets load error was captured at launch, fire its toast
        // now (once) so the user sees it in context as they invoke Cai, instead of
        // as a decontextualized floating pill at app startup.
        if let pendingError = ContextSnippetsManager.shared.consumePendingLoadError() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(
                    name: .caiShowToast, object: nil,
                    userInfo: ["message": pendingError]
                )
            }
        }

        // If window is already visible, dismiss first
        hideWindow()

        // Skip resume cache when opening directly to settings
        if showSettings {
            clearCache()
        }

        // Resume: if reopened with the same text within the timeout, restore the
        // previous window (preserving result view, custom prompt state, etc.)
        if let cached = cachedWindow,
           let cachedText = cachedText,
           let dismissTime = cachedDismissTime,
           cachedText == text,
           Date().timeIntervalSince(dismissTime) < Self.resumeTimeout {
            print("♻️ Resuming previous window (dismissed \(String(format: "%.1f", Date().timeIntervalSince(dismissTime)))s ago)")
            self.window = cached
            self.currentText = cachedText  // Restore so next hideWindow() can re-cache it
            Self.passThrough = cachedPassThrough
            Self.submitScreenActive = cachedSubmitScreenActive
            self.cachedWindow = nil
            self.cachedText = nil
            self.cachedPassThrough = false
            self.cachedSubmitScreenActive = false
            self.cachedDismissTime = nil
            cacheCleanupTimer?.invalidate()
            cacheCleanupTimer = nil

            cached.alphaValue = 0
            NSApp.activate(ignoringOtherApps: true)
            cached.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
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

        let savedSize = Self.loadWindowSize()
        let currentWidth = savedSize?.width ?? Self.windowWidth
        let windowHeight = savedSize?.height ?? Self.fixedWindowHeight

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
            sourceBundleId: sourceBundleId,
            onDismiss: dismissAction,
            onExecute: executeAction,
            showSettingsOnAppear: showSettings
        )

        // Wrap in a hosting view (keyboard events are handled exclusively
        // by the keyMonitor local event monitor — no onKeyDown needed here
        // to avoid double-handling).
        let hostingView = KeyEventHostingView(
            rootView: actionList
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: currentWidth, height: windowHeight)
        hostingView.autoresizingMask = [.width, .height]  // follow panel when user drags to resize
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = Self.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true

        // Create borderless resizable CaiPanel (custom subclass returns YES from canBecomeKey).
        // `.resizable` + min=default-size lets the user grow the window from any
        // edge or corner (Finder-style), but never shrink below the canonical
        // Spotlight footprint. Both dimensions saved across launches.
        let panel = CaiPanel(
            contentRect: NSRect(x: 0, y: 0, width: currentWidth, height: windowHeight),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // We draw our own shadow in SwiftUI
        panel.level = .floating
        panel.isMovableByWindowBackground = true  // Drag to reposition
        panel.contentView = hostingView
        panel.minSize = NSSize(width: Self.windowWidth, height: Self.fixedWindowHeight)
        panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Allow the panel to become key so we receive keyboard events
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        // Restore last saved position, or center on screen
        if let savedOrigin = Self.loadWindowPosition() {
            panel.setFrameOrigin(savedOrigin)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - currentWidth / 2
            let y = screenFrame.midY - windowHeight / 2 + 50
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.window = panel

        // Activate our app temporarily so the panel can become key
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Fade in — 80ms feels instant while still preventing a harsh pop-in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }

        installEventMonitors()

        print("Action window shown with \(actions.count) actions (height: \(windowHeight))")
    }

    func hideWindow() {
        // Save window position and resized dimensions before dismissing
        if let frame = window?.frame {
            Self.saveWindowPosition(frame.origin)
            Self.saveWindowSize(frame.size)
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
            cachedSubmitScreenActive = Self.submitScreenActive
            cachedDismissTime = Date()

            // Auto-destroy the cache after the resume timeout
            cacheCleanupTimer?.invalidate()
            cacheCleanupTimer = Timer.scheduledTimer(withTimeInterval: Self.resumeTimeout, repeats: false) { [weak self] _ in
                self?.clearCache()
            }
        }
        Self.passThrough = false
        Self.submitScreenActive = false
        Self.acceptsFilterInput = true
        window = nil
        currentText = nil
        actions = []
    }

    // MARK: - Event Monitors

    private func installEventMonitors() {
        // Monitor for clicks outside the window to dismiss (LOCAL events — within our app).
        // Fast path: if the event targets our own window, let it flow to the responder
        // chain without a frame check. Otherwise we race against SwiftUI animations
        // (e.g., window resize on filter-text change or settings open) — a click on a
        // button that lands a pixel outside the mid-animation frame would incorrectly
        // dismiss the window, swallowing the button action.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let window = self.window else { return event }

            // Click is inside our own panel — pass through, the view will handle it.
            if event.window === window {
                return event
            }

            // Otherwise the click targets a different window in our process (NSMenu,
            // popover, sheet) or no window at all. Use the global mouse location as
            // ground truth — per-window coord translation can lie during resize/
            // animation races with .resizable panels, causing spurious dismissals
            // on legitimate in-window clicks (e.g. the gear icon).
            let mouseScreen = NSEvent.mouseLocation
            // Inflate the hit rect slightly so resize-grabber margins around a
            // borderless .resizable panel don't read as "outside".
            let slack: CGFloat = 4
            let hitRect = window.frame.insetBy(dx: -slack, dy: -slack)
            if !hitRect.contains(mouseScreen) {
                self.hideWindow()
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
            guard let self = self, let panel = self.window else { return event }
            // Only keys aimed at the action panel. Cai's other windows (the
            // agent-proposal review sheet, the management screens) own their
            // own keyboard; without this the panel would swallow their Return
            // and Esc whenever it happened to be open behind them.
            guard panel.isKeyWindow else { return event }
            if self.handleKeyEvent(event) {
                return nil  // Consumed — suppress the event
            }
            return event  // Pass through to responder chain
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
    }

    private func clearCache() {
        cachedWindow?.orderOut(nil)
        cachedWindow = nil
        cachedText = nil
        cachedDismissTime = nil
        // Reset the cached screen-state flags too. The resume path only reads them
        // when cachedWindow != nil (now nil), but don't leave them stale-true where
        // a future code path could apply them to an unrelated window.
        cachedPassThrough = false
        cachedSubmitScreenActive = false
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

    /// Whether a Return keypress should submit the active screen instead of
    /// inserting a newline. Only a *bare* Return submits — any modifier (Shift,
    /// Option, Control) inserts a newline. Cmd+Return is handled separately and
    /// always submits. Shared by the window key monitor and `ForwardingTextView`
    /// (the form editors) so the rule is identical everywhere. Pure and isolated
    /// from the view so the decision is unit-testable.
    static func returnSubmitsPrompt(pressReturnToSend: Bool, submitScreenActive: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard submitScreenActive, pressReturnToSend else { return false }
        // CapsLock is intentionally ignored — only intentional modifiers block submit.
        return modifiers.intersection([.shift, .option, .control, .command]).isEmpty
    }

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

        // Cmd+Return — captured only on screens that submit through this monitor
        // (Ask AI, follow-up, MCP form). On the other text-input screens — the form
        // editors built on MultilineTextEditor (Destinations / Shortcuts / inline
        // edit) — let it flow to the responder chain so the form's own ⌘⏎ handler
        // (ForwardingTextView / the Save button shortcut) fires instead of being
        // swallowed here into a no-op.
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            if Self.submitScreenActive {
                NotificationCenter.default.post(name: .caiCmdEnterPressed, object: nil)
                return true
            }
            return false
        }

        // Tab — trigger follow-up mode (only when no text editor is active)
        if event.keyCode == 48 {
            if !Self.passThrough {
                NotificationCenter.default.post(
                    name: .caiTabPressed,
                    object: nil
                )
            }
            // Always consume Tab to prevent focus cycling between UI elements
            return true
        }

        // When a text editor is active, plain Return normally inserts a newline
        // and arrows move the cursor — let those pass through. Exception: in the
        // Ask AI composer with "Press Return to send" on, a plain Return (no
        // Shift) submits instead, and Shift+Return inserts the newline. Cmd+Return
        // is handled above and always submits.
        if Self.passThrough {
            if event.keyCode == 36 {  // Return
                if Self.returnSubmitsPrompt(
                    pressReturnToSend: CaiSettings.shared.pressReturnToSend,
                    submitScreenActive: Self.submitScreenActive,
                    modifiers: event.modifierFlags
                ) {
                    NotificationCenter.default.post(name: .caiCmdEnterPressed, object: nil)
                    return true  // submit — swallow so no newline is inserted
                }
                return false  // newline (modified Return, setting off, or another screen)
            }
            if event.keyCode == 126 || event.keyCode == 125 {
                return false  // arrows move the cursor
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

        // Cmd+N — new action (no clipboard context)
        if event.modifierFlags.contains(.command) && event.keyCode == 45 {  // 45 = 'N'
            NotificationCenter.default.post(name: .caiCmdNPressed, object: nil)
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

        // Type-to-filter: capture printable characters and backspace.
        // Posts notifications so the active screen (actions or history) routes to the correct SelectionState.
        if !Self.passThrough && Self.acceptsFilterInput && !event.modifierFlags.contains(.command) {
            // Backspace
            if event.keyCode == 51 {
                NotificationCenter.default.post(name: .caiFilterBackspace, object: nil)
                return true
            }

            // Printable characters
            let significantFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasOnlyShift = significantFlags.subtracting(.shift).isEmpty
            if hasOnlyShift,
               let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
               chars.rangeOfCharacter(from: .controlCharacters) == nil {
                let typed = event.characters ?? chars
                NotificationCenter.default.post(
                    name: .caiFilterCharacter,
                    object: nil,
                    userInfo: ["char": typed]
                )
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
            let baseURL = CaiSettings.shared.searchURL.isEmpty ? CaiSettings.defaultSearchURL : CaiSettings.shared.searchURL
            SystemActions.searchWeb(query, searchBaseURL: baseURL)
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

    /// Queues a pill-shaped toast. Each message gets its full `duration` on
    /// screen (1.5s by default) before the next one appears, so two events a
    /// moment apart produce two readable toasts rather than one flicker.
    /// Callers can override per-message via the `duration` arg or the
    /// notification userInfo `"duration"` key.
    func showToast(message: String, duration: TimeInterval = 1.5, icon: ToastQueue.Icon = .success) {
        toastQueue.enqueue(
            ToastQueue.Request(message: message, duration: duration, icon: icon),
            showing: showingToastMessage
        )
        presentNextToastIfIdle()
    }

    private func presentNextToastIfIdle() {
        guard showingToastMessage == nil, let request = toastQueue.next() else { return }
        showingToastMessage = request.message
        presentToast(request.message, icon: request.icon)

        // Scheduled once per shown toast, and only while the slot is occupied,
        // so a previous toast's timer can never dismiss its successor early.
        DispatchQueue.main.asyncAfter(deadline: .now() + request.duration) { [weak self] in
            self?.finishCurrentToast()
        }
    }

    private func finishCurrentToast() {
        hideToast()
        showingToastMessage = nil
        // Slightly longer than the 0.2s fade, so consecutive toasts read as
        // two messages instead of one that changed its mind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.presentNextToastIfIdle()
        }
    }

    private func presentToast(_ message: String, icon: ToastQueue.Icon) {
        // Pure AppKit toast — no NSHostingView. NSHostingView on borderless
        // panels triggers an infinite constraint update loop that crashes in
        // _postWindowNeedsUpdateConstraints during the display cycle.
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        pill.layer?.cornerRadius = 18

        let glyph: NSImage
        if let symbolName = icon.symbolName {
            glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        } else {
            glyph = Self.caiMarkImage()
        }
        let imageView = NSImageView(image: glyph)
        imageView.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        pill.addSubview(imageView)
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 20),
            imageView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])

        let labelSize = label.intrinsicContentSize
        let width = ceil(20 + 14 + 8 + labelSize.width + 20)
        let height: CGFloat = 36

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
        panel.contentView = pill
        panel.ignoresMouseEvents = true

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - width / 2
            let y = screenFrame.maxY - 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.toastWindow = panel
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    /// The Cai mark, drawn white for the dark toast pill. Same shape as the
    /// menu bar icon, so an unsolicited toast is recognisably from Cai rather
    /// than an anonymous black rectangle over the user's work.
    private static func caiMarkImage() -> NSImage {
        let height: CGFloat = 11
        let size = NSSize(width: height * (217.0 / 127.0), height: height)
        return NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(CaiLogoShape().path(in: CGRect(origin: .zero, size: rect.size)).cgPath)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.fillPath()
            return true
        }
    }

    private func hideToast() {
        guard let toast = toastWindow else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            toast.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Act on the panel this fade belongs to, not on `toastWindow`: a
            // successor presented inside the fade window (an arrival toast
            // landing right as the previous one finishes) would otherwise be
            // ordered out by a completion that isn't theirs.
            toast.orderOut(nil)
            if self?.toastWindow === toast { self?.toastWindow = nil }
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

    /// Guards against re-entrant constraint invalidation that crashes in
    /// `NSWindow._postWindowNeedsUpdateConstraints`. During `updateConstraints()`,
    /// the SwiftUI view graph can change (size computation → `graphDidChange`),
    /// which triggers `setNeedsUpdateConstraints:YES` re-entrantly. AppKit throws
    /// because constraint invalidation can't happen during an active update pass.
    private var isUpdatingConstraints = false

    override func updateConstraints() {
        isUpdatingConstraints = true
        super.updateConstraints()
        isUpdatingConstraints = false
    }

    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if isUpdatingConstraints {
                // Suppress re-entrant constraint invalidation — the next
                // display cycle will pick up any pending changes.
                return
            }
            super.needsUpdateConstraints = newValue
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure we become first responder so the panel stays key
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
}
