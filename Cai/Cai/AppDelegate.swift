import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    private let hotKeyManager = HotKeyManager()
    private let clipboardService = ClipboardService.shared
    private let contentDetector = ContentDetector.shared
    private let windowController = WindowController()
    private let permissionsManager = PermissionsManager.shared
    private let clipboardHistory = ClipboardHistory.shared
    private var aboutWindow: NSWindow?
    private var shortcutsWindow: NSWindow?
    private var destinationsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Render CaiLogo Shape into a template NSImage for the menu bar
            let logoHeight: CGFloat = 11
            let logoWidth: CGFloat = logoHeight * (217.0 / 127.0)  // Preserve aspect ratio
            let size = NSSize(width: logoWidth, height: logoHeight)
            let image = NSImage(size: size, flipped: true) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                let swiftPath = CaiLogoShape().path(in: CGRect(origin: .zero, size: rect.size))
                ctx.addPath(swiftPath.cgPath)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
                return true
            }
            image.isTemplate = true  // Adapts to light/dark menu bar
            button.image = image
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            print("Status bar item created with Cai logo")
        } else {
            print("Failed to create status bar button")
        }

        // Create popover for left-click — shows settings
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 340, height: 440)
        popover?.behavior = .transient
        let settingsView = SettingsView(
            onShowShortcuts: { [weak self] in
                self?.popover?.performClose(nil)
                self?.showShortcutsWindow()
            },
            onShowDestinations: { [weak self] in
                self?.popover?.performClose(nil)
                self?.showDestinationsWindow()
            }
        )
        popover?.contentViewController = NSHostingController(rootView: settingsView)

        // Check accessibility permission
        permissionsManager.checkAccessibilityPermission()

        if !permissionsManager.hasAccessibilityPermission {
            // Show the system accessibility prompt (registers Cai in the list)
            permissionsManager.requestAccessibilityPermission()
            permissionsManager.startPollingForPermission()

            // If still not granted after 5 minutes, show our onboarding
            // window + a local notification as a gentle reminder.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard self?.permissionsManager.hasAccessibilityPermission == false else { return }
                self?.showOnboardingWindow()
                self?.permissionsManager.schedulePermissionReminderIfNeeded()
            }
        }

        // Auto-detect LLM provider on launch:
        // - First launch (no saved preference): probe all known ports
        // - Saved provider not reachable: fall back to whatever is running
        Task {
            let status = await LLMService.shared.checkStatus()
            if !status.available {
                await CaiSettings.shared.autoDetectProvider()
            }
        }

        // Check for updates (once per day)
        Task {
            await UpdateChecker.shared.checkForUpdate()
        }

        // Setup global hotkey (Option+C)
        setupHotKey()

        // Listen for permission changes to re-register hotkey and dismiss onboarding
        NotificationCenter.default.addObserver(
            forName: .accessibilityPermissionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if self?.permissionsManager.hasAccessibilityPermission == true {
                print("Accessibility permission granted - re-registering hotkey")
                self?.setupHotKey()
                self?.dismissOnboardingWindow()
            }
        }
    }

    @objc func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: show menu
            showMenu()
        } else {
            // Left-click: toggle settings popover
            togglePopover()
        }
    }

    func showMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Cai", action: #selector(openCai), keyEquivalent: "")
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openSettings), keyEquivalent: ","))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "About Cai", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Cai", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func togglePopover() {
        if let button = statusItem?.button {
            if let popover = popover {
                if popover.isShown {
                    popover.performClose(nil)
                } else {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
            }
        }
    }

    @objc func openSettings() {
        togglePopover()
    }

    @objc func openCai() {
        // Use whatever is already on the clipboard — don't simulate Cmd+C
        // because by the time the user clicks this menu item, the frontmost
        // app is Cai itself (or the menu bar), not the app with selected text.
        openWithClipboard()
    }

    func showShortcutsWindow() {
        // If already open, bring to front
        if let existing = shortcutsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let shortcutsView = ShortcutsManagementView(onBack: { [weak self] in
            self?.shortcutsWindow?.close()
        })
        let hostingView = NSHostingView(rootView: shortcutsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Custom Shortcuts"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 300)
        window.center()

        self.shortcutsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showDestinationsWindow() {
        // If already open, bring to front
        if let existing = destinationsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let destinationsView = DestinationsManagementView(onBack: { [weak self] in
            self?.destinationsWindow?.close()
        })
        let hostingView = NSHostingView(rootView: destinationsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Output Destinations"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 300)
        window.center()

        self.destinationsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout() {
        // If already open, bring to front
        if let existing = aboutWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let aboutView = AboutView()
        let hostingView = NSHostingView(rootView: aboutView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Cai"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()

        self.aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reads clipboard content and shows the action window, or shows a toast if empty.
    private func openWithClipboard(sourceApp: String? = nil) {
        if let content = clipboardService.readClipboard() {
            // Record to clipboard history
            clipboardHistory.recordCurrentClipboard()

            // Detect content type
            let detection = contentDetector.detect(content)
            print("Detected: \(detection.type.rawValue) (confidence: \(detection.confidence))")

            // Show the action window immediately — LLM errors handled at execution time
            windowController.showActionWindow(
                text: content,
                detection: detection,
                sourceApp: sourceApp
            )
        } else {
            print("Clipboard is empty")
            windowController.showToast(message: "Clipboard is empty")
        }
    }

    // MARK: - Onboarding Window

    private func showOnboardingWindow() {
        let onboardingView = OnboardingPermissionView()
        let hostingView = NSHostingView(rootView: onboardingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cai Setup"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()

        self.onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func setupHotKey() {
        // Register Option+C as the global hotkey
        hotKeyManager.register { [weak self] in
            self?.handleHotKeyTrigger()
        }
    }

    func handleHotKeyTrigger() {
        print("Hotkey triggered")

        // If the action window is already visible, dismiss it (toggle behavior)
        if windowController.isVisible {
            windowController.hideWindow()
            return
        }

        // Capture the frontmost app name before Cmd+C simulation steals focus
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // Always simulate Cmd+C to capture the current selection.
        // Most apps (browsers, mail clients) don't expose AXSelectedText,
        // so we can't reliably check for a selection beforehand.
        // If nothing is selected, Cmd+C is a no-op and we fall back to
        // whatever is already on the clipboard.
        clipboardService.copySelectedText { [weak self] in
            self?.openWithClipboard(sourceApp: sourceApp)
        }
    }
}
