import SwiftUI

struct ActionListWindow: View {
    let text: String
    let detection: ContentResult
    let actions: [ActionItem]
    @ObservedObject var selectionState: SelectionState
    let sourceApp: String?
    let onDismiss: () -> Void
    let onExecute: (ActionItem) -> Void
    var showSettingsOnAppear: Bool = false

    @State private var showResult: Bool = false
    @State private var resultTitle: String = ""
    @State private var resultGenerator: (() async throws -> String)?
    @State private var pendingResultText: String = ""
    @State private var showSettings: Bool = false
    @State private var showHistory: Bool = false
    @State private var showCustomPrompt: Bool = false
    @State private var showShortcutsManagement: Bool = false
    @State private var showDestinationsManagement: Bool = false
    @State private var showExtensionBrowser: Bool = false
    @State private var showConnectors: Bool = false
    @StateObject private var historySelectionState = SelectionState()
    @StateObject private var customPromptState = CustomPromptState()
    @ObservedObject private var settings = CaiSettings.shared
    @ObservedObject private var sparkleUpdater = SparkleUpdater.shared

    // Follow-up conversation state
    @State private var conversationHistory: [ChatMessage] = []
    @State private var isFollowUpEnabled: Bool = false
    @State private var showFollowUpInput: Bool = false
    @State private var followUpText: String = ""
    @State private var resultViewId: Int = 0
    @State private var isNewAction: Bool = false
    @State private var shortcutDisplayName: String?

    // Extension install confirmation
    @State private var showExtensionConfirm: Bool = false
    @State private var pendingExtension: ExtensionParser.ParsedExtension?

    // MCP form state
    @State private var showMCPForm: Bool = false
    @State private var activeMCPActionConfig: MCPActionConfig?
    @State private var mcpFormInstanceId: UUID = UUID()  // Forces fresh @State on each open

    @State private var availableModels: [String] = []
    @State private var showModelPicker: Bool = false
    @State private var currentModelName: String = ""
    @State private var isSwitchingModel: Bool = false

    /// Corner radius matching Spotlight's rounded appearance
    private let cornerRadius: CGFloat = 20

    /// Which screen is currently active — used for keyboard routing
    private var activeScreen: Screen {
        if showExtensionConfirm { return .extensionConfirm }
        if showMCPForm { return .mcpForm }
        if showConnectors { return .connectors }
        if showExtensionBrowser { return .extensionBrowser }
        if showDestinationsManagement { return .destinationsManagement }
        if showShortcutsManagement { return .shortcutsManagement }
        if showSettings { return .settings }
        if showHistory { return .history }
        if showResult { return .result }
        if showCustomPrompt { return .customPrompt }
        return .actions
    }

    private enum Screen {
        case actions, result, settings, history, customPrompt, shortcutsManagement, destinationsManagement, extensionBrowser, extensionConfirm, mcpForm, connectors
    }

    /// Actions to display — when filtering, merges built-in actions + user shortcuts,
    /// renumbered sequentially. Uses case-insensitive prefix matching:
    /// typing "ex" matches "Explain" (title starts with "ex").
    /// Checks if any word in `text` starts with `query`.
    /// "note" matches "Save to Notes", but "ote" does not.
    private func anyWordHasPrefix(_ text: String, query: String) -> Bool {
        let words = text.lowercased().split(separator: " ")
        return words.contains { $0.hasPrefix(query) }
    }

    private var displayedActions: [ActionItem] {
        guard !selectionState.filterText.isEmpty else { return actions }

        let query = selectionState.filterText.lowercased()
        var items: [ActionItem] = []
        var shortcut = 1

        // Filter built-in actions — any word in title must start with query
        for action in actions {
            if anyWordHasPrefix(action.title, query: query) {
                items.append(ActionItem(
                    id: action.id,
                    title: action.title,
                    subtitle: action.subtitle,
                    icon: action.icon,
                    shortcut: shortcut,
                    type: action.type
                ))
                shortcut += 1
            }
        }

        // Add matching user shortcuts — any word prefix match on name.
        // (Shortcuts aren't in ActionGenerator output; they only appear via search.)
        let clipboardText = text
        for sc in settings.shortcuts {
            if anyWordHasPrefix(sc.name, query: query) {
                let actionType: ActionType
                let subtitle: String
                switch sc.type {
                case .prompt:
                    actionType = .llmAction(.custom(sc.value))
                    subtitle = sc.value
                case .url:
                    actionType = .shortcutURL(sc.value)
                    subtitle = sc.value.replacingOccurrences(of: "%s", with: clipboardText.prefix(20) + (clipboardText.count > 20 ? "…" : ""))
                case .shell:
                    actionType = .shortcutShell(sc.value)
                    subtitle = sc.value
                }

                items.append(ActionItem(
                    id: "shortcut_\(sc.id.uuidString)",
                    title: sc.name,
                    subtitle: subtitle,
                    icon: sc.type.icon,
                    shortcut: shortcut,
                    type: actionType
                ))
                shortcut += 1
            }
        }

        // Note: output destinations are already in `actions` (appended by ActionGenerator),
        // so they're included in the filter loop above — no separate loop needed.

        return items
    }

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectBackground()

            // Faint indigo tint — brand presence without competing with content
            Color.caiPrimary.opacity(0.05)
                .allowsHitTesting(false)

            if showExtensionConfirm, let ext = pendingExtension {
                extensionConfirmView(ext)
            } else if showMCPForm, let config = activeMCPActionConfig {
                MCPFormView(
                    actionConfig: config,
                    clipboardText: text,
                    sourceApp: sourceApp,
                    contentType: detection.type,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showMCPForm = false
                            activeMCPActionConfig = nil
                        }
                    },
                    onDismiss: onDismiss
                )
                .id(mcpFormInstanceId) // Unique per open — forces fresh @State so .task re-fires
            } else if showDestinationsManagement {
                DestinationsManagementView(
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showDestinationsManagement = false
                            showSettings = true
                        }
                    }
                )
            } else if showExtensionBrowser {
                ExtensionBrowserView(
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showExtensionBrowser = false
                            showSettings = true
                        }
                    }
                )
            } else if showConnectors {
                ConnectorsSettingsView(
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showConnectors = false
                            showSettings = true
                        }
                    }
                )
            } else if showShortcutsManagement {
                ShortcutsManagementView(
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showShortcutsManagement = false
                            showSettings = true
                        }
                    }
                )
            } else if showCustomPrompt {
                CustomPromptView(
                    clipboardText: isNewAction ? "" : text,
                    sourceApp: isNewAction ? nil : sourceApp,
                    state: customPromptState,
                    onSubmit: { instruction in
                        handleCustomPromptSubmit(instruction)
                    }
                )
            } else if showSettings {
                settingsContent
            } else if showHistory {
                ClipboardHistoryView(
                    selectionState: historySelectionState,
                    onSelect: { entry in
                        ClipboardHistory.shared.copyEntry(entry)
                        copyAndDismissWithToast()
                    },
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showHistory = false
                        }
                    }
                )
            } else if showResult, let generator = resultGenerator {
                ResultView(
                    title: resultTitle,
                    onBack: { goBackToActions() },
                    onResult: { text in
                        pendingResultText = text
                        if isFollowUpEnabled {
                            conversationHistory.append(
                                ChatMessage(role: "assistant", content: text))
                        }
                    },
                    destinations: settings.enabledDestinations,
                    onSelectDestination: { dest, resultText in
                        executeDestination(dest, with: resultText)
                    },
                    isFollowUpEnabled: isFollowUpEnabled,
                    showFollowUpInput: $showFollowUpInput,
                    followUpText: $followUpText,
                    generator: generator
                )
                .id(resultViewId)
            } else {
                actionListContent
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.caiDivider.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        .onReceive(NotificationCenter.default.publisher(for: .caiExecuteAction)) { notification in
            if let actionId = notification.userInfo?["actionId"] as? String,
               let action = actions.first(where: { $0.id == actionId }) {
                executeAction(action)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiEscPressed)) { _ in
            handleEsc()
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiShowClipboardHistory)) { _ in
            handleShowHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiCmdNumber)) { notification in
            if let number = notification.userInfo?["number"] as? Int {
                handleCmdNumber(number)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiArrowUp)) { _ in
            handleArrowUp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiArrowDown)) { _ in
            handleArrowDown()
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiEnterPressed)) { _ in
            handleEnter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiTabPressed)) { _ in
            handleTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiCmdEnterPressed)) { _ in
            handleCmdEnter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiCmdNPressed)) { _ in
            handleNewAction()
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiFilterCharacter)) { notification in
            if let char = notification.userInfo?["char"] as? String {
                handleFilterCharacter(char)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .caiFilterBackspace)) { _ in
            handleFilterBackspace()
        }
        .onChange(of: showSettings) { _ in updateFilterInputFlag() }
        .onChange(of: showHistory) { _ in updateFilterInputFlag() }
        .onChange(of: showResult) { _ in updateFilterInputFlag() }
        .onChange(of: showCustomPrompt) { _ in updateFilterInputFlag() }
        .onChange(of: showShortcutsManagement) { _ in updateFilterInputFlag() }
        .onChange(of: showDestinationsManagement) { _ in updateFilterInputFlag() }
        .onChange(of: showMCPForm) { _ in updateFilterInputFlag() }
        .onChange(of: showConnectors) { _ in updateFilterInputFlag() }
        .onChange(of: showExtensionConfirm) { _ in updateFilterInputFlag() }
        .onChange(of: showFollowUpInput) { _ in updateFilterInputFlag() }
        .onReceive(NotificationCenter.default.publisher(for: .caiShowSettings)) { _ in
            if showSettings {
                // Already showing settings — toggle off (dismiss)
                onDismiss()
            } else {
                // Navigate to settings from current screen
                showResult = false
                showHistory = false
                showCustomPrompt = false
                showShortcutsManagement = false
                showDestinationsManagement = false
                showExtensionConfirm = false
                showMCPForm = false
                showConnectors = false
                activeMCPActionConfig = nil
                withAnimation(.easeInOut(duration: 0.15)) {
                    showSettings = true
                }
            }
        }
        .onAppear {
            updateFilterInputFlag()
            if showSettingsOnAppear {
                showSettings = true
            }
        }
    }

    /// Accept type-to-filter input on both the action list and history screens.
    private func updateFilterInputFlag() {
        WindowController.acceptsFilterInput = (activeScreen == .actions || activeScreen == .history)
    }

    /// Filtered history entries for keyboard routing (mirrors ClipboardHistoryView.displayedEntries)
    private var displayedHistoryEntries: [ClipboardHistory.Entry] {
        let all = ClipboardHistory.shared.allEntries
        guard !historySelectionState.filterText.isEmpty else { return all }
        let query = historySelectionState.filterText.lowercased()
        return all.filter { $0.text.lowercased().contains(query) }
    }

    // MARK: - Keyboard Routing

    private func handleEsc() {
        if showExtensionConfirm {
            withAnimation(.easeInOut(duration: 0.15)) {
                showExtensionConfirm = false
                pendingExtension = nil
            }
        } else if showMCPForm {
            // If a picker dropdown is open, MCPFormView handles ESC internally — skip navigation
            if MCPFormView.pickerDropdownOpen { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                showMCPForm = false
                activeMCPActionConfig = nil
            }
        } else if showConnectors {
            withAnimation(.easeInOut(duration: 0.15)) {
                showConnectors = false
                showSettings = true
            }
        } else if showExtensionBrowser {
            withAnimation(.easeInOut(duration: 0.15)) {
                showExtensionBrowser = false
                showSettings = true
            }
        } else if showDestinationsManagement {
            withAnimation(.easeInOut(duration: 0.15)) {
                showDestinationsManagement = false
                showSettings = true
            }
        } else if showShortcutsManagement {
            withAnimation(.easeInOut(duration: 0.15)) {
                showShortcutsManagement = false
                showSettings = true
            }
        } else if showCustomPrompt {
            withAnimation(.easeInOut(duration: 0.15)) {
                showCustomPrompt = false
                customPromptState.reset()
                isNewAction = false
            }
        } else if showSettings {
            withAnimation(.easeInOut(duration: 0.15)) {
                showSettings = false
            }
        } else if showHistory {
            if !historySelectionState.filterText.isEmpty {
                // Clear filter first; second Esc goes back
                historySelectionState.filterText = ""
                historySelectionState.selectedIndex = 0
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showHistory = false
                }
            }
        } else if showResult {
            if showFollowUpInput {
                showFollowUpInput = false
                followUpText = ""
            } else {
                goBackToActions()
            }
        } else if !selectionState.filterText.isEmpty {
            // Clear filter first; second Esc dismisses
            selectionState.filterText = ""
            selectionState.selectedIndex = 0
        } else {
            onDismiss()
        }
    }

    private func handleShowHistory() {
        guard activeScreen == .actions else { return }
        selectionState.filterText = ""
        historySelectionState.selectedIndex = 0
        historySelectionState.filterText = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            showHistory = true
        }
    }

    private func handleCmdNumber(_ number: Int) {
        switch activeScreen {
        case .actions:
            let visible = displayedActions
            if let action = visible.first(where: { $0.shortcut == number }) {
                if let index = visible.firstIndex(where: { $0.id == action.id }) {
                    selectionState.selectedIndex = index
                }
                executeAction(action)
            }
        case .result:
            // Cmd+1..9 on result screen → execute output destination
            let dests = settings.enabledDestinations
            let destIndex = number - 1
            guard destIndex >= 0, destIndex < dests.count,
                  !pendingResultText.isEmpty else { return }
            executeDestination(dests[destIndex], with: pendingResultText)
        case .history:
            let historyIndex = number - 1
            let entries = displayedHistoryEntries
            guard historyIndex >= 0, historyIndex < entries.count else { return }
            historySelectionState.selectedIndex = historyIndex
            ClipboardHistory.shared.copyEntry(entries[historyIndex])
            copyAndDismissWithToast()
        default:
            break
        }
    }

    private func handleArrowUp() {
        switch activeScreen {
        case .actions:
            let count = displayedActions.count
            guard count > 0 else { return }
            let current = selectionState.selectedIndex
            selectionState.selectedIndex = current > 0 ? current - 1 : count - 1
        case .history:
            let count = displayedHistoryEntries.count
            guard count > 0 else { return }
            let current = historySelectionState.selectedIndex
            historySelectionState.selectedIndex = current > 0 ? current - 1 : count - 1
        default:
            break
        }
    }

    private func handleArrowDown() {
        switch activeScreen {
        case .actions:
            let count = displayedActions.count
            guard count > 0 else { return }
            let current = selectionState.selectedIndex
            selectionState.selectedIndex = current < count - 1 ? current + 1 : 0
        case .history:
            let count = displayedHistoryEntries.count
            guard count > 0 else { return }
            let current = historySelectionState.selectedIndex
            historySelectionState.selectedIndex = current < count - 1 ? current + 1 : 0
        default:
            break
        }
    }

    private func handleEnter() {
        switch activeScreen {
        case .actions:
            let visible = displayedActions
            let index = selectionState.selectedIndex
            guard index < visible.count else { return }
            executeAction(visible[index])
        case .history:
            let entries = displayedHistoryEntries
            let index = historySelectionState.selectedIndex
            guard index < entries.count else { return }
            ClipboardHistory.shared.copyEntry(entries[index])
            copyAndDismissWithToast()
        case .result:
            if !pendingResultText.isEmpty {
                SystemActions.copyToClipboard(pendingResultText)
            }
            copyAndDismissWithToast()
        case .extensionConfirm:
            confirmInstallExtension()
        case .mcpForm:
            // Enter on success screen → dismiss
            onDismiss()
        default:
            break
        }
    }

    private func copyAndDismissWithToast() {
        // Dismiss first — orderOut removes the main window from the display
        // hierarchy so the toast's NSHostingView doesn't conflict with it.
        onDismiss()
        NotificationCenter.default.post(
            name: .caiShowToast,
            object: nil,
            userInfo: ["message": "Copied to Clipboard"]
        )
    }

    private func handleFilterCharacter(_ char: String) {
        switch activeScreen {
        case .actions:
            selectionState.filterText.append(char)
            selectionState.selectedIndex = 0
        case .history:
            historySelectionState.filterText.append(char)
            historySelectionState.selectedIndex = 0
        default:
            break
        }
    }

    private func handleFilterBackspace() {
        switch activeScreen {
        case .actions:
            if !selectionState.filterText.isEmpty {
                selectionState.filterText.removeLast()
                selectionState.selectedIndex = 0
            }
        case .history:
            if !historySelectionState.filterText.isEmpty {
                historySelectionState.filterText.removeLast()
                historySelectionState.selectedIndex = 0
            }
        default:
            break
        }
    }

    private func handleTab() {
        guard activeScreen == .result, isFollowUpEnabled, !showFollowUpInput,
              !pendingResultText.isEmpty else { return }
        showFollowUpInput = true
    }

    private func handleNewAction() {
        guard activeScreen == .actions else { return }
        selectionState.filterText = ""
        isNewAction = true
        customPromptState.reset()
        withAnimation(.easeInOut(duration: 0.15)) {
            showCustomPrompt = true
        }
    }

    private func handleCmdEnter() {
        if activeScreen == .mcpForm {
            submitMCPForm()
            return
        }
        guard activeScreen == .result, showFollowUpInput else { return }
        submitFollowUp()
    }

    private func submitMCPForm() {
        // Find the MCPFormView and call submit — we pass it via a notification
        NotificationCenter.default.post(name: .caiMCPFormSubmit, object: nil)
    }

    private func submitFollowUp() {
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        conversationHistory.append(ChatMessage(role: "user", content: trimmed))
        let messages = conversationHistory

        showFollowUpInput = false
        followUpText = ""
        pendingResultText = ""
        WindowController.passThrough = false

        resultGenerator = {
            return try await LLMService.shared.generateWithMessages(messages)
        }
        resultViewId += 1
    }

    /// Builds the initial [ChatMessage] array for an LLM action, including "About You" context.
    private func buildInitialMessages(systemPrompt: String, userPrompt: String) -> [ChatMessage] {
        let aboutYou = settings.aboutYou
        var finalSystem = systemPrompt
        if !aboutYou.isEmpty {
            finalSystem = "About the user: \(aboutYou)\n\n\(finalSystem)"
        }
        return [
            ChatMessage(role: "system", content: finalSystem),
            ChatMessage(role: "user", content: userPrompt)
        ]
    }

    private func goBackToActions() {
        withAnimation(.easeInOut(duration: 0.15)) {
            showResult = false
            showFollowUpInput = false
            resultGenerator = nil
            resultTitle = ""
            pendingResultText = ""
            conversationHistory = []
            isFollowUpEnabled = false
            followUpText = ""
            isNewAction = false
        }
    }

    // MARK: - Action List Content

    private var actionListContent: some View {
        let visible = displayedActions
        return VStack(spacing: 0) {
            headerView

            // Filter bar — appears when user starts typing
            if !selectionState.filterText.isEmpty {
                filterBarView
            }

            updateBanner
            crashReportingPrompt

            Divider()
                .background(Color.caiDivider)

            ScrollViewReader { proxy in
                ScrollView {
                    if visible.isEmpty {
                        VStack(spacing: 8) {
                            Text("No matches")
                                .font(.system(size: 13))
                                .foregroundColor(.caiTextSecondary)
                            Text("Try a different search or create a custom action in Settings")
                                .font(.system(size: 11))
                                .foregroundColor(.caiTextSecondary.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .padding()
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, action in
                                ActionRow(action: action, isSelected: index == selectionState.selectedIndex)
                                    .id(action.id)
                                    .onTapGesture {
                                        selectionState.selectedIndex = index
                                        executeAction(visible[index])
                                    }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                    }
                }
                .onChange(of: selectionState.selectedIndex) { newValue in
                    if newValue < visible.count {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(visible[newValue].id, anchor: .center)
                        }
                    }
                }
            }

            Divider()
                .background(Color.caiDivider)

            mainFooterView
        }
    }

    // MARK: - Settings Content (inline)

    private var settingsContent: some View {
        VStack(spacing: 0) {
            SettingsView(
                onShowShortcuts: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSettings = false
                        showShortcutsManagement = true
                    }
                },
                onShowDestinations: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSettings = false
                        showDestinationsManagement = true
                    }
                },
                onShowExtensions: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSettings = false
                        showExtensionBrowser = true
                    }
                },
                onShowConnectors: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSettings = false
                        showConnectors = true
                    }
                },
                onShowModelSetup: {
                    NotificationCenter.default.post(name: .caiShowModelSetup, object: nil)
                },
                onDismiss: onDismiss
            )
            Spacer(minLength: 0)
            Divider()
                .background(Color.caiDivider)
            HStack(spacing: 16) {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Filter Bar

    private var filterBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary.opacity(0.6))

            Text(selectionState.filterText)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.caiTextPrimary)

            Spacer()

            Text("type to filter")
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.caiSurface.opacity(0.4))
    }

    // MARK: - Update Banner

    @ViewBuilder
    private var updateBanner: some View {
        if sparkleUpdater.updateAvailable {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                Text("A new version of Cai is available")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)

                Spacer()

                Button("Update") {
                    sparkleUpdater.checkForUpdates()
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.caiPrimary)
        }
    }

    // MARK: - Crash Reporting Prompt

    @ViewBuilder
    private var crashReportingPrompt: some View {
        if !settings.crashReportingPromptShown && !sparkleUpdater.updateAvailable {
            HStack(spacing: 8) {
                Image(systemName: "ladybug")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                Text("Send anonymous crash reports?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)

                Spacer()

                Button("Enable") {
                    settings.crashReportingEnabled = true
                    settings.crashReportingPromptShown = true
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .buttonStyle(.plain)

                Button("Nope") {
                    settings.crashReportingPromptShown = true
                }
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.6))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.caiPrimary)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: iconForType(detection.type))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiPrimary)

            VStack(alignment: .leading, spacing: 1) {
                Text(labelForType(detection.type))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary)

                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear { fetchCurrentModel() }
    }

    private var modelChipView: some View {
        Menu {
            if settings.modelProvider == .builtIn {
                // Built-in: list local .gguf files from models folder
                let localModels = CaiSettings.scanBuiltInModels()
                if localModels.isEmpty {
                    Text("No models found")
                } else {
                    ForEach(localModels, id: \.self) { fileName in
                        Button(action: {
                            let newPath = BuiltInLLM.modelsDirectory
                                .appendingPathComponent(fileName).path
                            guard newPath != settings.builtInModelPath else { return }
                            switchBuiltInModel(to: newPath, fileName: fileName)
                        }) {
                            HStack {
                                Text(fileName)
                                if fileName == settings.builtInModelFileName {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } else {
                // External provider: list models from server API
                if availableModels.isEmpty {
                    Text("Loading models…")
                } else {
                    ForEach(availableModels, id: \.self) { model in
                        Button(action: {
                            settings.modelName = model
                            currentModelName = shortenModelName(model)
                        }) {
                            HStack {
                                Text(model)
                                if model == resolvedFullModelName() {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    Divider()

                    Button("Auto-detect") {
                        settings.modelName = ""
                        Task { await refreshCurrentModel() }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.caiTextSecondary.opacity(0.5))
                if isSwitchingModel {
                    Text("Loading…")
                        .font(.system(size: 10))
                        .foregroundColor(.caiTextSecondary.opacity(0.6))
                } else {
                    Text(currentModelName)
                        .font(.system(size: 10))
                        .foregroundColor(.caiTextSecondary.opacity(0.6))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear {
            Task {
                if settings.modelProvider != .builtIn {
                    availableModels = await LLMService.shared.availableModels()
                }
            }
        }
    }

    private func switchBuiltInModel(to newPath: String, fileName: String) {
        isSwitchingModel = true
        currentModelName = shortenModelName(fileName)
        Task {
            settings.builtInModelPath = newPath
            try? await BuiltInLLM.shared.restart(modelPath: newPath)
            await MainActor.run {
                isSwitchingModel = false
            }
            await refreshCurrentModel()
        }
    }

    private func fetchCurrentModel() {
        Task {
            let status = await LLMService.shared.checkStatus()
            let userModel = settings.modelName
            let name = !userModel.isEmpty ? userModel : (status.modelName ?? "")
            await MainActor.run {
                currentModelName = shortenModelName(name)
            }
        }
    }

    private func refreshCurrentModel() async {
        let status = await LLMService.shared.checkStatus()
        let userModel = await MainActor.run { settings.modelName }
        let name = !userModel.isEmpty ? userModel : (status.modelName ?? "")
        await MainActor.run {
            currentModelName = shortenModelName(name)
        }
    }

    /// Returns the full model name that's currently active (user override or auto-detected)
    private func resolvedFullModelName() -> String {
        let userModel = settings.modelName
        return !userModel.isEmpty ? userModel : currentModelName
    }

    /// Shortens model names for the chip display
    /// e.g. "lmstudio-community/qwen3-4b-GGUF" → "qwen3-4b"
    /// Max display chars for model name in footer chip (keeps footer from wrapping)
    private let maxModelNameDisplay = 10

    private func shortenModelName(_ name: String) -> String {
        // Strip org prefix (e.g. "lmstudio-community/")
        let base = name.components(separatedBy: "/").last ?? name
        // Strip common suffixes
        let short = base
            .replacingOccurrences(of: "-GGUF", with: "")
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: ":latest", with: "")
        // Always truncate to a fixed width so all models look consistent
        if short.count > maxModelNameDisplay {
            return String(short.prefix(maxModelNameDisplay)) + "…"
        }
        return short
    }

    // MARK: - Footer (Main Action View)

    private var mainFooterView: some View {
        HStack(spacing: 10) {
            KeyboardHint(key: "↑↓", label: "Navigate")
            KeyboardHint(key: "↵", label: "Select")
            KeyboardHint(key: "Esc", label: selectionState.filterText.isEmpty ? "Close" : "Clear")
            if selectionState.filterText.isEmpty {
                KeyboardHint(key: "⌘0", label: "History")
                KeyboardHint(key: "⌘N", label: "New")
            }

            Spacer()

            // Model name chip — click to switch models
            if !currentModelName.isEmpty {
                modelChipView
            }

            Button(action: {
                selectionState.filterText = ""
                withAnimation(.easeInOut(duration: 0.15)) {
                    showSettings = true
                }
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Settings")
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func iconForType(_ type: ContentType) -> String {
        switch type {
        case .caiExtension: return "puzzlepiece.extension"
        case .url: return "link"
        case .json: return "curlybraces"
        case .address: return "mappin.and.ellipse"
        case .meeting: return "calendar"
        case .word: return "textformat.abc"
        case .shortText: return "text.alignleft"
        case .longText: return "doc.text"
        case .image: return "photo"
        case .empty: return "tray"
        }
    }

    private func labelForType(_ type: ContentType) -> String {
        switch type {
        case .caiExtension: return "Cai Extension"
        case .url: return "URL detected"
        case .json: return "JSON detected"
        case .address: return "Address detected"
        case .meeting: return "Date/Meeting detected"
        case .word: return "Word detected"
        case .shortText: return "Text detected"
        case .longText: return "Long text detected"
        case .image: return "Text extracted from image"
        case .empty: return "Nothing on clipboard"
        }
    }

    // MARK: - Actions

    private func executeAction(_ action: ActionItem) {
        CrashReportingService.shared.addBreadcrumb(category: "action", message: "Execute: \(action.title)")
        switch action.type {
        case .jsonPrettyPrint(let json):
            isFollowUpEnabled = false
            showResultView(title: "Pretty Print JSON") {
                return Self.prettyPrintJSON(json)
            }

        case .llmAction(let llmAction):
            // Set shortcutDisplayName for custom shortcuts (action.title has the shortcut name)
            if case .custom = llmAction {
                shortcutDisplayName = action.title
            }
            let title = llmActionTitle(llmAction)
            let clipboardText = self.text
            let app = self.sourceApp

            let prompts = LLMService.prompts(for: llmAction, text: clipboardText, appContext: app)
            let initialMessages = buildInitialMessages(systemPrompt: prompts.system, userPrompt: prompts.user)
            conversationHistory = initialMessages
            isFollowUpEnabled = true

            showResultView(title: title) {
                return try await LLMService.shared.generateWithMessages(initialMessages)
            }

        case .customPrompt:
            selectionState.filterText = ""
            customPromptState.reset()
            withAnimation(.easeInOut(duration: 0.15)) {
                showCustomPrompt = true
            }

        case .shortcutURL(let template):
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            let urlString = template.replacingOccurrences(of: "%s", with: encoded)
            if let url = URL(string: urlString) {
                SystemActions.openURL(url)
            }
            onDismiss()

        case .shortcutShell(let command):
            let clipboardText = self.text
            let systemPrompt = "You are a helpful assistant. The user ran a shell command on their clipboard text. Help them with any questions about the output."
            conversationHistory = buildInitialMessages(systemPrompt: systemPrompt, userPrompt: clipboardText)
            isFollowUpEnabled = true
            showResultView(title: action.title) {
                return try await Self.runShellCommand(command, text: clipboardText)
            }

        case .copyText:
            let extractedText = self.text
            let systemPrompt = "You are a helpful assistant. The user shared text extracted from an image via OCR. Help them with any questions about it. For math, use Unicode symbols."
            conversationHistory = buildInitialMessages(systemPrompt: systemPrompt, userPrompt: extractedText)
            // onResult callback will append the assistant message with extractedText
            isFollowUpEnabled = true
            showResultView(title: "Extracted Text") {
                return extractedText
            }

        case .installExtension:
            installExtension()

        case .mcpAction(let configId):
            if let config = MCPConfigManager.shared.availableActions.first(where: { $0.id == configId }) {
                // If API key not configured, redirect to Connectors setup
                if !MCPConfigManager.shared.isServerConfigured(config.serverConfigId) {
                    selectionState.filterText = ""
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showConnectors = true
                    }
                    return
                }
                selectionState.filterText = ""
                activeMCPActionConfig = config
                mcpFormInstanceId = UUID()  // Fresh view identity — resets all @State
                withAnimation(.easeInOut(duration: 0.15)) {
                    showMCPForm = true
                }
            }

        case .outputDestination(let destination):
            executeDestination(destination, with: text)

        default:
            // System actions (openURL, openMaps, search, createCalendar)
            onExecute(action)
        }
    }

    private func showResultView(title: String, generator: @escaping () async throws -> String) {
        selectionState.filterText = ""
        resultTitle = title
        resultGenerator = generator
        pendingResultText = ""
        showFollowUpInput = false
        followUpText = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            showResult = true
        }
    }

    private func handleCustomPromptSubmit(_ instruction: String) {
        showCustomPrompt = false
        shortcutDisplayName = nil

        if isNewAction || text.isEmpty {
            // New action mode — no clipboard context, general assistant
            let systemPrompt = "You are a helpful assistant. Answer clearly and concisely. For math, use Unicode symbols."
            let initialMessages = buildInitialMessages(systemPrompt: systemPrompt, userPrompt: instruction)
            conversationHistory = initialMessages
            isFollowUpEnabled = true
            isNewAction = false

            showResultView(title: instruction) {
                return try await LLMService.shared.generateWithMessages(initialMessages)
            }
        } else {
            // Existing custom action flow — clipboard text as context
            let clipboardText = self.text
            let app = self.sourceApp

            let prompts = LLMService.prompts(for: .custom(instruction), text: clipboardText, appContext: app)
            let initialMessages = buildInitialMessages(systemPrompt: prompts.system, userPrompt: prompts.user)
            conversationHistory = initialMessages
            isFollowUpEnabled = true

            showResultView(title: instruction) {
                return try await LLMService.shared.generateWithMessages(initialMessages)
            }
        }
    }

    private func llmActionTitle(_ action: LLMAction) -> String {
        switch action {
        case .summarize: return "Summary"
        case .translate(let lang): return "Translation (\(lang))"
        case .define: return "Definition"
        case .explain: return "Explanation"
        case .reply: return "Reply"
        case .proofread: return "Fix Grammar"
        case .custom: return shortcutDisplayName ?? "Custom"
        }
    }

    // MARK: - Extension Confirm View

    private func extensionConfirmView(_ ext: ExtensionParser.ParsedExtension) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: ext.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.caiPrimary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ext.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.caiTextPrimary)
                    Text(ext.typeLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Details
            VStack(alignment: .leading, spacing: 10) {
                if let desc = ext.extensionDescription, !desc.isEmpty {
                    detailRow(label: "Description", value: desc)
                }

                if let author = ext.author, !author.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Author")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.caiTextSecondary)
                            .textCase(.uppercase)
                        Button(action: {
                            if let url = URL(string: "https://github.com/\(author)") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 4) {
                                GitHubIcon(color: .caiPrimary)
                                    .frame(width: 10, height: 10)
                                Text(author)
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(.caiPrimary)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                }

                if let detail = ext.securityDetail {
                    detailRow(label: "Sends data to", value: detail, isWarning: true)
                }

                // Trust warning
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.caiError)
                    Text("Extensions can modify your clipboard text and send data to external services.")
                        .font(.system(size: 10))
                        .foregroundColor(.caiTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Actions
            HStack(spacing: 10) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showExtensionConfirm = false
                        pendingExtension = nil
                    }
                }) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(Color.caiSurface.opacity(0.4))
                .cornerRadius(6)

                Button(action: {
                    confirmInstallExtension()
                }) {
                    Text("Install")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(Color.caiPrimary)
                .cornerRadius(6)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Spacer(minLength: 0)

            // Footer
            Divider()
            HStack(spacing: 16) {
                KeyboardHint(key: "Esc", label: "Cancel")
                Spacer()
                KeyboardHint(key: "↵", label: "Install")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func detailRow(label: String, value: String, isWarning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.caiTextSecondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(isWarning ? .orange : .caiTextPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    // MARK: - Extension Install

    private func installExtension() {
        do {
            let parsed = try ExtensionParser.parse(text)
            pendingExtension = parsed
            withAnimation(.easeInOut(duration: 0.15)) {
                showExtensionConfirm = true
            }
        } catch {
            let message = error.localizedDescription
            isFollowUpEnabled = false
            showResultView(title: "Install Extension") {
                throw NSError(domain: "Cai", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }

    private func confirmInstallExtension() {
        guard let parsed = pendingExtension else { return }

        switch parsed {
        case .shortcut(let shortcut, _, _):
            // Check for existing shortcut with same name → update
            if let index = settings.shortcuts.firstIndex(where: { $0.name == shortcut.name }) {
                settings.shortcuts[index].type = shortcut.type
                settings.shortcuts[index].value = shortcut.value
                onDismiss()
                NotificationCenter.default.post(
                    name: .caiShowToast,
                    object: nil,
                    userInfo: ["message": "Updated: \(shortcut.name)"]
                )
            } else {
                settings.shortcuts.append(shortcut)
                onDismiss()
                NotificationCenter.default.post(
                    name: .caiShowToast,
                    object: nil,
                    userInfo: ["message": "Installed: \(shortcut.name)"]
                )
            }

        case .destination(let destination, _, _):
            // Check for existing destination with same name → update
            if let index = settings.outputDestinations.firstIndex(where: { $0.name == destination.name && !$0.isBuiltIn }) {
                settings.outputDestinations[index].type = destination.type
                settings.outputDestinations[index].icon = destination.icon
                settings.outputDestinations[index].showInActionList = destination.showInActionList
                settings.outputDestinations[index].setupFields = destination.setupFields
                onDismiss()
                NotificationCenter.default.post(
                    name: .caiShowToast,
                    object: nil,
                    userInfo: ["message": "Updated: \(destination.name)"]
                )
            } else {
                settings.outputDestinations.append(destination)
                onDismiss()
                NotificationCenter.default.post(
                    name: .caiShowToast,
                    object: nil,
                    userInfo: ["message": "Installed: \(destination.name)"]
                )
            }
        }
    }

    // MARK: - Output Destinations

    private func executeDestination(_ destination: OutputDestination, with text: String) {
        // Always copy to clipboard first
        SystemActions.copyToClipboard(text)

        Task {
            do {
                try await OutputDestinationService.shared.execute(destination, with: text)
                await MainActor.run {
                    // Dismiss first — orderOut removes the main window from the
                    // display hierarchy so the toast's NSHostingView doesn't conflict.
                    onDismiss()
                    NotificationCenter.default.post(
                        name: .caiShowToast,
                        object: nil,
                        userInfo: ["message": "Sent to \(destination.name)"]
                    )
                }
            } catch {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .caiShowToast,
                        object: nil,
                        userInfo: ["message": "Failed: \(error.localizedDescription)"]
                    )
                }
            }
        }
    }

    // MARK: - Static helpers

    private static func prettyPrintJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8) else {
            return json
        }
        return result
    }

    /// Runs a shell command template with clipboard text substituted for {{result}}.
    /// Text is also piped as stdin. Returns stdout on success, throws on failure/timeout.
    private static func runShellCommand(_ template: String, text: String) async throws -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        let resolved = template.replacingOccurrences(of: "{{result}}", with: escaped)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", resolved]

        // Pass text as stdin
        let inputPipe = Pipe()
        let inputData = text.data(using: .utf8) ?? Data()
        inputPipe.fileHandleForWriting.write(inputData)
        inputPipe.fileHandleForWriting.closeFile()
        process.standardInput = inputPipe

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Timeout after 15 seconds
        let deadline = DispatchTime.now() + .seconds(15)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }

        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw NSError(domain: "Cai", code: 1, userInfo: [NSLocalizedDescriptionKey: "Command timed out after 15 seconds"])
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderr.isEmpty ? "Command failed with exit code \(process.terminationStatus)" : stderr
            throw NSError(domain: "Cai", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }

        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
