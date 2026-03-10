import SwiftUI

/// Settings panel — used both inline in the action window (via Cai logo)
/// and in the menu bar popover. Adapts to parent's size constraints.
struct SettingsView: View {
    @ObservedObject var settings = CaiSettings.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared
    /// Callback to navigate to shortcuts management. When rendered inside
    /// ActionListWindow this pushes the shortcuts screen; when rendered in the
    /// menu bar popover this opens a standalone window.
    var onShowShortcuts: (() -> Void)? = nil
    var onShowDestinations: (() -> Void)? = nil
    var onShowModelSetup: (() -> Void)? = nil

    /// LLM connection status — checked each time settings opens.
    @State private var llmConnected: Bool? = nil  // nil = checking
    /// Available models from the current provider
    @State private var availableModels: [String] = []

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                CaiLogo(color: .caiPrimary)
                    .frame(width: 18, height: 10.5)
                Text("Cai Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)
                Spacer()
                Text("v\(appVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary.opacity(0.4))
                updateBadge
                llmStatusIndicator
                permissionIndicator
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Translation Language
                    settingsSection(title: "Translation Language", icon: "globe") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: $settings.translationLanguage) {
                                ForEach(CaiSettings.commonLanguages, id: \.self) { lang in
                                    Text(lang).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityLabel("Translation language")

                            Text("Default language for the Translate action")
                                .font(.system(size: 11))
                                .foregroundColor(.caiTextSecondary)
                        }
                    }

                    // Search URL
                    settingsSection(title: "Search URL", icon: "magnifyingglass") {
                        TextField(CaiSettings.defaultSearchURL, text: $settings.searchURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .accessibilityLabel("Search engine base URL")
                            .onChange(of: settings.searchURL) { newValue in
                                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    settings.searchURL = CaiSettings.defaultSearchURL
                                }
                            }
                    }

                    // Maps Provider
                    settingsSection(title: "Maps", icon: "map") {
                        Picker("", selection: $settings.mapsProvider) {
                            ForEach(CaiSettings.MapsProvider.allCases) { provider in
                                Text(provider.rawValue).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityLabel("Maps provider")
                    }

                    // Model Provider
                    settingsSection(title: "Model Provider", icon: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: $settings.modelProvider) {
                                ForEach(CaiSettings.ModelProvider.allCases) { provider in
                                    Text(provider.rawValue).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityLabel("LLM model provider")

                            if settings.modelProvider == .builtIn {
                                builtInModelSection
                            } else {
                                if settings.modelProvider == .custom {
                                    TextField("http://127.0.0.1:8080", text: $settings.customModelURL)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                        .accessibilityLabel("Custom model URL")

                                    Text("OpenAI-compatible API endpoint (\(settings.modelURL))")
                                        .font(.system(size: 11))
                                        .foregroundColor(.caiTextSecondary)
                                }

                                // Model picker
                                HStack(spacing: 8) {
                                    Picker("", selection: $settings.modelName) {
                                        Text("Auto-detect").tag("")
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .accessibilityLabel("Model selection")

                                    Button(action: { fetchAvailableModels() }) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.caiTextSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Refresh model list")
                                }

                                Text("Select a model or leave on Auto-detect")
                                    .font(.system(size: 10))
                                    .foregroundColor(.caiTextSecondary.opacity(0.6))

                                // API Key (optional, for cloud or auth-enabled servers)
                                SecureField("Optional", text: $settings.apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .accessibilityLabel("API key for authenticated LLM providers")

                                Text("API key — leave blank for local servers without auth")
                                    .font(.system(size: 10))
                                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                            }
                        }
                        .onChange(of: settings.modelProvider) { newProvider in
                            if newProvider == .builtIn {
                                startBuiltInIfNeeded()
                            }
                            forceCheckLLMStatus()
                            if newProvider != .builtIn {
                                fetchAvailableModels()
                            }
                        }
                        .onChange(of: settings.customModelURL) { _ in forceCheckLLMStatus(); fetchAvailableModels() }
                        .onChange(of: settings.modelName) { _ in forceCheckLLMStatus() }
                    }

                    // Custom Shortcuts
                    settingsSection(title: "Custom Shortcuts", icon: "bolt.circle.fill") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let onShowShortcuts = onShowShortcuts {
                                Button(action: onShowShortcuts) {
                                    shortcutsRow
                                }
                                .buttonStyle(.plain)
                            } else {
                                shortcutsRow
                            }
                            Text("Type to search shortcuts when Cai is open")
                                .font(.system(size: 11))
                                .foregroundColor(.caiTextSecondary)
                        }
                    }

                    // Output Destinations
                    settingsSection(title: "Output Destinations", icon: "arrow.up.right.square") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let onShowDestinations = onShowDestinations {
                                Button(action: onShowDestinations) {
                                    destinationsRow
                                }
                                .buttonStyle(.plain)
                            } else {
                                destinationsRow
                            }
                            Text("Send LLM results to Mail, Notes, Slack, and more")
                                .font(.system(size: 11))
                                .foregroundColor(.caiTextSecondary)
                        }
                    }

                    // About You
                    settingsSection(title: "About You", icon: "person.circle") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(
                                "e.g. My name is Alex. I'm a product designer based in Berlin. I prefer casual, concise replies. I speak English and German.",
                                text: $settings.aboutYou,
                                axis: .vertical
                            )
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .accessibilityLabel("About you — personal context for AI responses")
                            .onChange(of: settings.aboutYou) { newValue in
                                if newValue.count > CaiSettings.aboutYouMaxLength {
                                    settings.aboutYou = String(newValue.prefix(CaiSettings.aboutYouMaxLength))
                                }
                            }

                            HStack {
                                Text("Personal context added to every AI response")
                                    .font(.system(size: 10))
                                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                                Spacer()
                                Text("\(settings.aboutYou.count) / \(CaiSettings.aboutYouMaxLength)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(
                                        settings.aboutYou.count > CaiSettings.aboutYouMaxLength - 50
                                            ? .orange
                                            : .caiTextSecondary.opacity(0.4)
                                    )
                            }
                        }
                    }

                    // Privacy
                    settingsSection(title: "Privacy", icon: "hand.raised") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Send crash reports", isOn: $settings.crashReportingEnabled)
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                                .accessibilityLabel("Send crash reports to help improve Cai")

                            Text("When enabled, anonymous crash data is sent to help fix bugs. No clipboard content, personal data, or usage patterns are collected.")
                                .font(.system(size: 10))
                                .foregroundColor(.caiTextSecondary.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // General
                    settingsSection(title: "General", icon: "gearshape") {
                        HStack {
                            Text("Hotkey")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                            Spacer()
                            ShortcutRecorderView()
                                .frame(width: 120, height: 24)
                        }

                        Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                            .font(.system(size: 12))
                            .foregroundColor(.caiTextPrimary)
                            .accessibilityLabel("Launch Cai at login")
                    }

                    // Feedback
                    Button(action: {
                        if let url = URL(string: "mailto:hi@getcai.app?subject=Cai%20Feedback") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "envelope")
                                .font(.system(size: 10, weight: .medium))
                            Text("Send Feedback")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .onAppear {
            permissions.checkAccessibilityPermission()
            checkLLMStatus()
            fetchAvailableModels()
        }
    }

    // MARK: - Built-in Model Section

    @ViewBuilder
    private var builtInModelSection: some View {
        let localModels = CaiSettings.scanBuiltInModels()

        if !localModels.isEmpty {
            // Model(s) available — show picker
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { settings.builtInModelFileName },
                        set: { newFileName in
                            let newPath = BuiltInLLM.modelsDirectory
                                .appendingPathComponent(newFileName).path
                            guard newPath != settings.builtInModelPath else { return }
                            switchBuiltInModel(to: newPath)
                        }
                    )) {
                        ForEach(localModels, id: \.self) { fileName in
                            Text(fileName).tag(fileName)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityLabel("Built-in model selection")

                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                        .help("Drop .gguf files into ~/Library/Application Support/Cai/models/")
                }

                HStack(spacing: 12) {
                    Text("Runs entirely on your Mac")
                        .font(.system(size: 10))
                        .foregroundColor(.caiTextSecondary.opacity(0.6))
                    Spacer()
                    Button("Delete Model") {
                        deleteBuiltInModel()
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.8))
                    .buttonStyle(.plain)
                }
            }
        } else {
            // No models — show download prompt
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text("No model downloaded")
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextSecondary)
                }

                Text("Download \(ModelDownloader.defaultModel.name) (\(ModelDownloader.defaultModel.formattedSize)) to use the built-in AI engine.")
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))

                Button(action: { onShowModelSetup?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                        Text("Download Model")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.caiPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func switchBuiltInModel(to newPath: String) {
        Task {
            settings.builtInModelPath = newPath
            try? await BuiltInLLM.shared.restart(modelPath: newPath)
            forceCheckLLMStatus()
        }
    }

    private func deleteBuiltInModel() {
        // Stop the server first
        Task {
            await BuiltInLLM.shared.stop()
        }

        // Delete the currently selected model file
        let modelPath = settings.builtInModelPath
        if !modelPath.isEmpty {
            try? FileManager.default.removeItem(atPath: modelPath)
        }

        // Try to fall back to another model in the folder
        let remaining = CaiSettings.scanBuiltInModels()
        if let next = remaining.first {
            let nextPath = BuiltInLLM.modelsDirectory.appendingPathComponent(next).path
            settings.builtInModelPath = nextPath
            Task {
                try? await BuiltInLLM.shared.start(modelPath: nextPath)
            }
        } else {
            settings.builtInModelPath = ""
            settings.builtInSetupDone = false
        }

        forceCheckLLMStatus()
    }

    // MARK: - Shortcuts Row

    private var shortcutsRow: some View {
        HStack {
            Text(settings.shortcuts.isEmpty
                 ? "Create shortcuts for prompts & URLs"
                 : "\(settings.shortcuts.count) shortcut\(settings.shortcuts.count == 1 ? "" : "s") configured")
                .font(.system(size: 12))
                .foregroundColor(.caiTextPrimary)
            Spacer()
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiPrimary)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Destinations Row

    private var destinationsRow: some View {
        HStack {
            let enabled = settings.enabledDestinations.count
            let total = settings.outputDestinations.count
            Text(total == 0
                 ? "Configure where to send results"
                 : "\(enabled) of \(total) destination\(total == 1 ? "" : "s") enabled")
                .font(.system(size: 12))
                .foregroundColor(.caiTextPrimary)
            Spacer()
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiPrimary)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Update Badge

    @ViewBuilder
    private var updateBadge: some View {
        if let version = updateChecker.availableVersion {
            Button(action: {
                updateChecker.openReleasePage()
            }) {
                Text("v\(version) available")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.caiPrimary)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Click to download Cai v\(version) from GitHub")
        }
    }

    // MARK: - LLM Status

    private var llmStatusIndicator: some View {
        Group {
            if let connected = llmConnected {
                Image(systemName: connected ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(connected ? .green : .orange)
            } else {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            }
        }
        .help(llmConnected == true
              ? "LLM server connected"
              : llmConnected == false
                ? "LLM server not reachable — check your provider"
                : "Checking LLM connection…")
    }

    private func checkLLMStatus() {
        // Skip re-check if already connected — avoid unnecessary network calls
        guard llmConnected != true else { return }
        forceCheckLLMStatus()
    }

    private func forceCheckLLMStatus() {
        llmConnected = nil
        Task {
            let status = await LLMService.shared.checkStatus()
            await MainActor.run {
                llmConnected = status.available
            }
        }
    }

    private func startBuiltInIfNeeded() {
        let modelPath = settings.builtInModelPath
        guard settings.builtInSetupDone,
              !modelPath.isEmpty,
              FileManager.default.fileExists(atPath: modelPath) else { return }

        Task {
            let isRunning = await BuiltInLLM.shared.isRunning
            if !isRunning {
                do {
                    try await BuiltInLLM.shared.start(modelPath: modelPath)
                    print("Built-in LLM started from Settings")
                } catch {
                    print("Failed to start built-in LLM from Settings: \(error.localizedDescription)")
                }
            }
            // Refresh status after starting
            await MainActor.run { forceCheckLLMStatus() }
        }
    }

    private func fetchAvailableModels() {
        Task {
            let models = await LLMService.shared.availableModels()
            await MainActor.run {
                availableModels = models
            }
        }
    }

    // MARK: - Permission Indicator

    private var permissionIndicator: some View {
        Button(action: {
            if !permissions.hasAccessibilityPermission {
                permissions.openAccessibilityPreferences()
            }
        }) {
            Image(systemName: permissions.hasAccessibilityPermission
                  ? "checkmark.shield.fill"
                  : "exclamationmark.shield.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(permissions.hasAccessibilityPermission ? .green : .orange)
        }
        .buttonStyle(.plain)
        .help(permissions.hasAccessibilityPermission
              ? "Accessibility permission granted"
              : "Accessibility permission required — click to open Settings")
    }

    // MARK: - Settings Section

    private func settingsSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiPrimary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)
            }
            content()
        }
    }
}
