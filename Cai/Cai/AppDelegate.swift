import Cocoa
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
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
    private var modelSetupWindow: NSWindow?
    private var pendingLLMSetup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply saved appearance preference
        CaiSettings.shared.applyAppearance()

        // Start crash reporting early if user has opted in
        CrashReportingService.shared.startIfEnabled()

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

        // Clean up any orphaned llama-server from a previous crash (legacy, safe to call)
        // Legacy llama-server cleanup (will be removed with BuiltInLLM.swift)

        // Start built-in LLM and/or show setup — but only after accessibility is resolved.
        // If accessibility is already granted, run immediately.
        // Otherwise, wait for the permission notification before showing the model setup window.
        if permissionsManager.hasAccessibilityPermission {
            startBuiltInLLMAndAutoDetect()
        } else {
            // Will be triggered when accessibility permission is granted
            pendingLLMSetup = true
        }

        // Initialize Sparkle auto-updater (checks for updates on its own schedule)
        _ = SparkleUpdater.shared

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

                // Now that accessibility is sorted, handle LLM setup
                if self?.pendingLLMSetup == true {
                    self?.pendingLLMSetup = false
                    self?.startBuiltInLLMAndAutoDetect()
                }
            }
        }

        // Listen for model setup requests from Settings
        NotificationCenter.default.addObserver(
            forName: .caiShowModelSetup,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showModelSetupWindow()
        }
    }

    @objc func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: show menu
            showMenu()
        } else {
            // Left-click: show settings in the main Cai window
            windowController.showSettingsWindow()
        }
    }

    func showMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Cai", action: #selector(openCai), keyEquivalent: "")
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "About Cai", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Cai", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func openSettings() {
        windowController.showSettingsWindow()
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
        window.title = "Custom Actions"
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
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 300),
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
    /// Priority: image file (Finder) → text → image data → empty.
    ///
    /// `sourceApp` is the display name ("Terminal"). `sourceBundleId` is the canonical
    /// key ("com.apple.Terminal") used by `ContextSnippetsManager` to match per-app
    /// snippets. Both are captured at hotkey time before Cmd+C simulation steals focus.
    private func openWithClipboard(sourceApp: String? = nil, sourceBundleId: String? = nil) {
        // 1. Image file on clipboard (e.g. Finder copy of a .png/.jpg) — OCR it
        //    Must come before text check: Finder puts both file URL and path text on the pasteboard,
        //    so readClipboard() would match the path string and skip OCR.
        if let ocrText = OCRService.shared.extractTextFromClipboardImageFile() {
            showImageOCRResult(ocrText: ocrText, sourceApp: sourceApp, sourceBundleId: sourceBundleId)

        // 2. Text found
        } else if let content = clipboardService.readClipboard() {
            clipboardHistory.recordCurrentClipboard()

            // Clamp text to prevent oversized LLM requests and UI slowdown
            let clampedContent = content.count > ClipboardHistory.maxTextLength
                ? String(content.prefix(ClipboardHistory.maxTextLength))
                : content

            let detection = contentDetector.detect(clampedContent)
            print("Detected: \(detection.type.rawValue) (confidence: \(detection.confidence))")
            CrashReportingService.shared.addBreadcrumb(category: "content", message: "Detected: \(detection.type.rawValue)")

            windowController.showActionWindow(
                text: clampedContent,
                detection: detection,
                sourceApp: sourceApp,
                sourceBundleId: sourceBundleId
            )

        // 3. Image data on clipboard (e.g. Preview copy, screenshot to clipboard) — OCR it
        } else if let ocrText = OCRService.shared.extractTextFromClipboardImage() {
            showImageOCRResult(ocrText: ocrText, sourceApp: sourceApp, sourceBundleId: sourceBundleId)

        // 4. Image present but OCR found no text — still open window
        } else if OCRService.shared.hasImageOnClipboard() || OCRService.shared.hasImageFileOnClipboard() {
            print("No text found in clipboard image — opening window")
            showEmptyWindow(sourceApp: sourceApp, sourceBundleId: sourceBundleId)

        // 5. Nothing on clipboard — still open window
        } else {
            print("Clipboard is empty — opening window")
            showEmptyWindow(sourceApp: sourceApp, sourceBundleId: sourceBundleId)
        }
    }

    /// Shows the action window with OCR-extracted text from an image.
    private func showImageOCRResult(ocrText: String, sourceApp: String?, sourceBundleId: String?) {
        clipboardHistory.recordImageClipboard(ocrText: ocrText)

        let detection = ContentResult(
            type: .image,
            confidence: 1.0,
            entities: ContentEntities()
        )
        print("Detected: image with OCR text (\(ocrText.count) chars)")
        CrashReportingService.shared.addBreadcrumb(category: "content", message: "Detected: image (OCR \(ocrText.count) chars)")

        windowController.showActionWindow(
            text: ocrText,
            detection: detection,
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId
        )
    }

    /// Opens the action window with no clipboard content (empty state).
    /// User can still use Cmd+N (new action) or Cmd+0 (clipboard history).
    private func showEmptyWindow(sourceApp: String?, sourceBundleId: String?) {
        let detection = ContentResult(
            type: .empty,
            confidence: 1.0,
            entities: ContentEntities()
        )

        windowController.showActionWindow(
            text: "",
            detection: detection,
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId
        )
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
        // Unload the MLX model before quitting — await so buffers are released
        Task {
            await MLXInference.shared.unload()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety net: unload MLX model if process is killed without going through quitApp()
        Task { await MLXInference.shared.unload() }

        // Disconnect all MCP servers
        Task { await MCPClientService.shared.disconnectAll() }
    }

    // MARK: - Model Setup Window

    private func showModelSetupWindow() {
        // If already open, bring to front
        if let existing = modelSetupWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let setupView = ModelSetupView(onComplete: { [weak self] in
            self?.modelSetupWindow?.close()
            self?.modelSetupWindow = nil
        })
        let hostingView = NSHostingView(rootView: setupView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cai Setup"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()

        self.modelSetupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Built-in LLM Startup

    private func startBuiltInLLMAndAutoDetect() {
        Task {
            let settings = await MainActor.run { CaiSettings.shared }
            let provider = await MainActor.run { settings.modelProvider }
            let setupDone = await MainActor.run { settings.builtInSetupDone }
            let modelId = await MainActor.run { settings.builtInModelId }

            // First launch — show onboarding so user can choose
            if !setupDone {
                await MainActor.run { [weak self] in
                    self?.showModelSetupWindow()
                }
                return
            }

            // Apple Intelligence — no model to load, just verify availability
            if provider == .apple {
                let status = await LLMService.shared.checkStatus()
                if status.available {
                    print("Apple Intelligence ready — no setup needed")
                    return
                }
            }

            // GGUF→MLX migration: show setup window so user sees download progress
            let needsMigration = await MainActor.run { settings.needsMLXMigration }
            if needsMigration && provider == .builtIn {
                await MainActor.run { [weak self] in
                    self?.showModelSetupWindow()
                }
                return
            }

            // Built-in MLX — load the user's selected model in-process
            if provider == .builtIn {
                let selectedId = modelId.isEmpty ? ModelCatalog.defaultModelId : modelId
                do {
                    try await MLXInference.shared.loadModel(id: selectedId)
                    print("🧠 Built-in MLX model loaded successfully")
                } catch {
                    print("⚠️ Failed to load built-in MLX model: \(error.localizedDescription)")
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .caiShowToast, object: nil,
                            userInfo: ["message": "Failed to load AI model. Check Settings."]
                        )
                    }
                }
                return
            }

            // External provider — check if it's available, otherwise auto-detect
            let status = await LLMService.shared.checkStatus()
            if !status.available {
                await settings.autoDetectProvider()

                let newProvider = await MainActor.run { settings.modelProvider }
                if newProvider == .apple {
                    print("Auto-detected Apple Intelligence — no setup needed")
                    return
                }

                // If auto-detect landed on built-in, load the user's selected model
                if newProvider == .builtIn {
                    let fallbackId = await MainActor.run { settings.builtInModelId }
                    let selectedId = fallbackId.isEmpty ? ModelCatalog.defaultModelId : fallbackId
                    do {
                        try await MLXInference.shared.loadModel(id: selectedId)
                        print("🧠 Built-in MLX model loaded after auto-detect")
                    } catch {
                        print("⚠️ Failed to load MLX model after auto-detect: \(error.localizedDescription)")
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .caiShowToast, object: nil,
                                userInfo: ["message": "Failed to load AI model. Check Settings."]
                            )
                        }
                    }
                }
            }
        }
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

        // Capture the frontmost app's display name AND bundle ID before Cmd+C
        // simulation steals focus. The display name feeds into LLM prompts
        // ("(from Terminal)") and the bundle ID is used by ContextSnippetsManager
        // to match per-app context snippets.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let sourceApp = frontmost?.localizedName
        let sourceBundleId = frontmost?.bundleIdentifier

        // Always simulate Cmd+C to capture the current selection.
        // Most apps (browsers, mail clients) don't expose AXSelectedText,
        // so we can't reliably check for a selection beforehand.
        // If nothing is selected, Cmd+C is a no-op and we fall back to
        // whatever is already on the clipboard.
        clipboardService.copySelectedText { [weak self] in
            self?.openWithClipboard(sourceApp: sourceApp, sourceBundleId: sourceBundleId)
        }
    }
}
