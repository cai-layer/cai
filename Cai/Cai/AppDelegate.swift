import Cocoa
import Combine
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
    /// The agent-proposal approval sheet. Reused while open, same as the
    /// model setup window.
    private var actionReviewWindow: NSWindow?
    private var pendingLLMSetup = false
    /// Subscription to `BackgroundTaskTracker` — drives the menu bar icon
    /// pulse while a background shell action is running.
    private var taskTrackerSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainThreadWatchdog.start()
        #endif

        // Apply saved appearance preference
        CaiSettings.shared.applyAppearance()

        // Start crash reporting early if user has opted in
        CrashReportingService.shared.startIfEnabled()

        // Create the status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = Self.statusItemImage(showsPendingDot: false)
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // Layer-backed so we can pulse the icon's opacity via Core Animation
            // when a background task is in flight (BackgroundTaskTracker).
            button.wantsLayer = true

            print("Status bar item created with Cai logo")
            // Build info — kept in logs so bug reports always include which build the user was running.
            // No secrets or PII; bundle ID, version, build number, and DEBUG/RELEASE only.
            let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let buildNum = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            #if DEBUG
            let config = "DEBUG"
            #else
            let config = "RELEASE"
            #endif
            print("Build: \(bundleId) v\(version) (\(buildNum)) [\(config)]")
        } else {
            print("Failed to create status bar button")
        }

        // Subscribe to BackgroundTaskTracker so the status bar icon pulses
        // while any background shell action is running. Using `removeDuplicates`
        // means we only animate on busy/idle TRANSITIONS, not on every counter
        // increment (multiple concurrent tasks pulse the same way as one).
        taskTrackerSubscription = BackgroundTaskTracker.shared.$activeTaskCount
            .map { $0 > 0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in
                if busy {
                    self?.startStatusBarPulse()
                } else {
                    self?.stopStatusBarPulse()
                }
            }

        // A proposal arriving never steals focus: the icon grows a dot and one
        // toast fires. The review window opens only when the user asks for it.
        //
        // Registered BEFORE the store starts: its first scan posts this
        // notification, and anything an agent queued while Cai was closed has
        // to raise the dot on this launch, not wait for the next proposal.
        NotificationCenter.default.addObserver(
            forName: .caiPendingChangesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePendingBadge() }
        }

        // Start watching for agent-authored proposals. No-ops when the kill
        // switch is off, and in Debug builds without CAI_MCP_PENDING=1 (both
        // bundle IDs share Application Support, so an unguarded Debug build
        // would race the Release build for the same pending files).
        PendingChangeStore.shared.startIfEnabled()
        updatePendingBadge()

        // Check accessibility permission
        permissionsManager.checkAccessibilityPermission()

        if !permissionsManager.hasAccessibilityPermission {
            // Show the system accessibility prompt (registers Cai in System Settings).
            // Skip in debug builds — each Xcode build changes the binary signature,
            // causing macOS to revoke the previous entry and spam the dialog.
            #if !DEBUG
            permissionsManager.requestAccessibilityPermission()
            #endif
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

        // Eagerly initialize ContextSnippetsManager so snippets.json is loaded and
        // validated at launch. If the file is malformed, the toast fires immediately
        // instead of waiting for the user to trigger their first LLM action.
        // Deferred one runloop tick so the toast observer is ready to receive it.
        DispatchQueue.main.async {
            _ = ContextSnippetsManager.shared
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

        // Only present while something waits: the review window is the one
        // place a proposal can be approved, so it needs a click path, but an
        // always-visible entry would advertise a queue that is usually empty.
        let pendingCount = MainActor.assumeIsolated { PendingChangeStore.shared.pending.count }
        if pendingCount > 0 {
            let title = pendingCount == 1
                ? "Review proposed action"
                : "Review proposed actions (\(pendingCount))"
            menu.addItem(NSMenuItem(title: title, action: #selector(showActionReview), keyEquivalent: ""))
        }

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
        Task { @MainActor in await openWithClipboard() }
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
    @MainActor
    private func openWithClipboard(sourceApp: String? = nil, sourceBundleId: String? = nil) async {
        // One atomic snapshot off the main thread (PasteboardQueue), then resolve
        // off the lane. A slow daemon (Universal Clipboard, huge item) can't freeze
        // the runloop, and detection sees a single consistent clipboard state
        // rather than a mix from several separate reads.
        let (content, changeCount) = await clipboardService.readClipboardContent()

        switch content {
        // Image (file OCR or image data). For a Finder copy the file URL wins over
        // the path string; if OCR finds no text, readClipboardContent falls through
        // to the path text, so we never land here with empty OCR.
        case .imageText(let ocrText):
            showImageOCRResult(ocrText: ocrText, sourceApp: sourceApp, sourceBundleId: sourceBundleId)

        // Text found.
        case .text(let text):
            clipboardHistory.recordCurrentClipboard(text, changeCount: changeCount)

            // No clamping here: ClipboardHistory already stores only the first
            // `maxTextLength` (10K) chars for its own UI, and `LLMService.truncateMessages`
            // caps the LLM input at 50K. Pre-clamping to 10K here would prevent the
            // LLM cap from ever engaging and silently cut useful context for long
            // summaries. The action list header surfaces a subtle "X chars → 50K
            // for AI" note when the clipboard exceeds the LLM cap.
            let detection = contentDetector.detect(text)
            print("Detected: \(detection.type.rawValue) (confidence: \(detection.confidence))")
            CrashReportingService.shared.addBreadcrumb(category: "content", message: "Detected: \(detection.type.rawValue)")

            windowController.showActionWindow(
                text: text,
                detection: detection,
                sourceApp: sourceApp,
                sourceBundleId: sourceBundleId
            )

        // No usable content — open an empty window. `hadImage` only picks the log line.
        case .empty(let hadImage):
            print(hadImage ? "No text found in clipboard image — opening window"
                           : "Clipboard is empty — opening window")
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
        // Drain any pending pasteboard writes (fire-and-forget copies) so a copy
        // made right before ⌘Q isn't lost when the process exits.
        PasteboardQueue.shared.flush()

        // Safety net: unload MLX model if process is killed without going through quitApp()
        Task { await MLXInference.shared.unload() }

        // Disconnect all MCP servers
        Task { await MCPClientService.shared.disconnectAll() }
    }

    // MARK: - Model Setup Window

    // MARK: - Agent Proposals

    /// Renders the menu bar logo, optionally with the pending-proposal dot.
    ///
    /// A template image, so the dot inherits the menu bar's own tint in light
    /// and dark rather than introducing colour where macOS expects none.
    private static func statusItemImage(showsPendingDot: Bool) -> NSImage {
        let logoHeight: CGFloat = 11
        let logoWidth: CGFloat = logoHeight * (217.0 / 127.0)  // Preserve aspect ratio
        let dotDiameter: CGFloat = 4
        let dotGap: CGFloat = 2
        let size = NSSize(
            width: logoWidth + (showsPendingDot ? dotGap + dotDiameter : 0),
            height: logoHeight
        )

        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let logoRect = CGRect(x: 0, y: 0, width: logoWidth, height: rect.height)
            let swiftPath = CaiLogoShape().path(in: logoRect)
            ctx.addPath(swiftPath.cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()

            if showsPendingDot {
                let dot = CGRect(
                    x: logoWidth + dotGap,
                    y: (rect.height - dotDiameter) / 2,
                    width: dotDiameter,
                    height: dotDiameter
                )
                ctx.addEllipse(in: dot)
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true  // Adapts to light/dark menu bar
        return image
    }

    /// Adds or clears the dot, and keeps an open review window sized to the
    /// proposal it is now showing.
    @MainActor
    private func updatePendingBadge() {
        let hasPending = !PendingChangeStore.shared.pending.isEmpty
        statusItem?.button?.image = Self.statusItemImage(showsPendingDot: hasPending)
        statusItem?.button?.toolTip = hasPending ? "Cai has a proposed action waiting for review" : nil

        // Re-fit on the next runloop pass, not now: this notification is posted
        // synchronously from the store, before SwiftUI has re-rendered for the
        // new queue. Measuring here would size the window to the proposal that
        // just left, clipping the payload of the one that replaced it.
        if let window = actionReviewWindow, window.isVisible {
            DispatchQueue.main.async { [weak self] in
                self?.resizeActionReviewWindow(window)
            }
        }
    }

    @MainActor
    @objc func showActionReview() {
        // Same reuse-if-open presentation as the model setup window.
        if let existing = actionReviewWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let reviewView = ActionReviewView(
            store: PendingChangeStore.shared,
            onClose: { [weak self] in
                self?.actionReviewWindow?.close()
                self?.actionReviewWindow = nil
            }
        )
        let hostingView = NSHostingView(rootView: reviewView)

        // Frosted, borderless, 20pt radius per docs/design/DESIGN.md. CaiPanel
        // rather than NSWindow because a borderless window cannot become key,
        // and this surface is keyboard-first (Return approves, Esc defers).
        let panel = CaiPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.reviewWindowWidth, height: hostingView.fittingSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.center()

        actionReviewWindow = panel
        resizeActionReviewWindow(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window fits its content, so advancing the queue from a one-line
    /// prompt to a 30-line shell script must not leave the payload clipped.
    private func resizeActionReviewWindow(_ window: NSWindow) {
        guard let hostingView = window.contentView else { return }
        guard let frame = Self.reviewWindowFrame(
            current: window.frame,
            contentHeight: hostingView.fittingSize.height
        ) else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    /// Where the review window goes for a given content height, or nil when it
    /// is already the right size.
    ///
    /// Pure because the growth direction is the part that goes wrong: AppKit
    /// origins are bottom-left, so keeping the header still while the sheet
    /// grows means moving the origin, and getting that backwards makes the
    /// window crawl down the screen every time the queue advances.
    static func reviewWindowFrame(current: NSRect, contentHeight: CGFloat) -> NSRect? {
        let height = max(contentHeight, minimumReviewWindowHeight)
        guard abs(current.height - height) > 0.5 else { return nil }
        return NSRect(
            x: current.origin.x,
            y: current.origin.y + (current.height - height),
            width: reviewWindowWidth,
            height: height
        )
    }

    /// 540pt fixed, per docs/design/DESIGN.md.
    static let reviewWindowWidth: CGFloat = 540
    /// Floor for the empty state, so the window can never collapse to a sliver.
    static let minimumReviewWindowHeight: CGFloat = 120

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
        // Skip the launch-time MLX model load under XCTest. The unit suite is fully
        // offline (pure helpers, request encoding, template/detector logic), so loading
        // a model here only adds startup cost and races MLX's global thread-pool
        // teardown when the test host exits mid-load ([ThreadPool::enqueue] on stopped
        // pool → fatal). No effect on the shipped app.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

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
            Task { @MainActor in
                await self?.openWithClipboard(sourceApp: sourceApp, sourceBundleId: sourceBundleId)
            }
        }
    }

    // MARK: - Status Bar Pulse (background-task indicator)

    /// Starts a continuous opacity pulse on the menu bar icon — visible signal
    /// that Cai is running a background task (e.g. a `|llm`-containing shell
    /// shortcut). Idempotent: re-adding the same animation key replaces the
    /// existing one, so calling this while already pulsing is fine.
    private func startStatusBarPulse() {
        guard let button = statusItem?.button else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(pulse, forKey: "caiPulse")
        button.toolTip = "Cai is working\u{2026}"
    }

    /// Stops the pulse animation and restores the icon to fully opaque.
    /// Removing the layer animation alone isn't enough — when the in-flight
    /// pulse cycle ends mid-frame, the layer may settle on a non-1.0 opacity,
    /// so we explicitly set `alphaValue = 1.0` to guarantee a clean visual reset.
    private func stopStatusBarPulse() {
        guard let button = statusItem?.button else { return }
        button.layer?.removeAnimation(forKey: "caiPulse")
        button.alphaValue = 1.0
        button.toolTip = nil
    }
}
