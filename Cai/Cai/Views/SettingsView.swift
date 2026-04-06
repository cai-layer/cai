import SwiftUI

/// Settings panel — shown inline in the action window (via gear icon or menu bar click).
struct SettingsView: View {
    @ObservedObject var settings = CaiSettings.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var sparkleUpdater = SparkleUpdater.shared
    /// Callback to navigate to shortcuts management (pushes inline screen).
    var onShowShortcuts: (() -> Void)? = nil
    var onShowDestinations: (() -> Void)? = nil
    var onShowExtensions: (() -> Void)? = nil
    var onShowConnectors: (() -> Void)? = nil
    var onShowModelSetup: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

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
                VStack(alignment: .leading, spacing: 24) {

                    // MARK: AI Group
                    settingsGroup(title: "AI") {
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
                                } else if settings.modelProvider == .apple {
                                    Text("On-device model via Apple Intelligence — no setup needed")
                                        .font(.system(size: 11))
                                        .foregroundColor(.caiTextSecondary)
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
                                if newProvider != .builtIn && newProvider != .apple {
                                    fetchAvailableModels()
                                }
                            }
                            .onChange(of: settings.customModelURL) { _ in forceCheckLLMStatus(); fetchAvailableModels() }
                            .onChange(of: settings.modelName) { _ in forceCheckLLMStatus() }
                        }

                        settingsDivider

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
                                    Text("Helps tailor replies, translations, etc.")
                                        .font(.system(size: 10))
                                        .foregroundColor(.caiTextSecondary.opacity(0.6))
                                    Spacer()
                                    Text("\(settings.aboutYou.count) / \(CaiSettings.aboutYouMaxLength)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(
                                            settings.aboutYou.count > CaiSettings.aboutYouMaxLength - 50
                                                ? .orange
                                                : .caiTextSecondary.opacity(0.5)
                                        )
                                }
                            }
                        }
                    }

                    // MARK: Actions Group
                    settingsGroup(title: "Actions") {
                        HStack {
                            Text("Translation")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                            Spacer()
                            Picker("", selection: $settings.translationLanguage) {
                                ForEach(CaiSettings.commonLanguages, id: \.self) { lang in
                                    Text(lang).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityLabel("Translation language")
                        }

                        settingsDivider

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Search URL")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
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

                        settingsDivider

                        HStack {
                            Text("Maps")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                            Spacer()
                            Picker("", selection: $settings.mapsProvider) {
                                ForEach(CaiSettings.MapsProvider.allCases) { provider in
                                    Text(provider.rawValue).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityLabel("Maps provider")
                        }
                    }

                    // MARK: Extensions Group
                    settingsGroup(title: "Extensions") {
                        navRow(label: "Custom Actions", count: settings.shortcuts.count, action: onShowShortcuts)

                        settingsDivider

                        connectorsNavRow

                        settingsDivider

                        navRow(label: "Destinations", count: settings.enabledDestinations.count, total: settings.outputDestinations.count, action: onShowDestinations)
                    }

                    Button(action: onShowExtensions ?? {}) {
                        HStack(spacing: 4) {
                            Text("Community extensions")
                                .font(.system(size: 11))
                                .foregroundColor(.caiPrimary)
                            if settings.installedExtensions.count > 0 {
                                Text("· \(settings.installedExtensions.count) installed")
                                    .font(.system(size: 11))
                                    .foregroundColor(.caiTextSecondary)
                            }
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.caiPrimary.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.top, -8)

                    // MARK: General Group
                    settingsGroup(title: "General") {
                        HStack {
                            Text("Hotkey")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                            Spacer()
                            ShortcutRecorderView()
                                .frame(width: 120, height: 24)
                        }

                        settingsDivider

                        HStack {
                            Text("Appearance")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                            Spacer()
                            Picker("", selection: $settings.appearance) {
                                ForEach(CaiSettings.Appearance.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityLabel("Appearance")
                        }

                        settingsDivider

                        HStack {
                            Text("Clipboard History")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                            Spacer()
                            Picker("", selection: $settings.clipboardHistorySize) {
                                ForEach(CaiSettings.historySizePresets, id: \.self) { size in
                                    Text("\(size) items").tag(size)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityLabel("Clipboard history size")
                        }

                        settingsDivider

                        HStack {
                            Text("Launch at Login")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                            Spacer()
                            Toggle("", isOn: $settings.launchAtLogin)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .tint(.caiPrimary)
                                .labelsHidden()
                        }
                        .accessibilityLabel("Launch Cai at login")

                        settingsDivider

                        HStack {
                            Text("Crash Reports")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextPrimary)
                            Spacer()
                            Toggle("", isOn: $settings.crashReportingEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .tint(.caiPrimary)
                                .labelsHidden()
                        }
                        .accessibilityLabel("Send crash reports to help improve Cai")
                    }

                    // Feedback & bug links
                    HStack(spacing: 12) {
                        Button(action: {
                            if let url = URL(string: "https://github.com/cai-layer/cai/discussions") {
                                NSWorkspace.shared.open(url)
                                onDismiss?()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 10, weight: .medium))
                                Text("Feedback")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            if let url = URL(string: "https://github.com/cai-layer/cai/issues") {
                                NSWorkspace.shared.open(url)
                                onDismiss?()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "ladybug")
                                    .font(.system(size: 10, weight: .medium))
                                Text("Report Bug")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
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

    private static let customModelTag = "__custom__"
    @State private var selectedModelId: String = ""
    @State private var customModelId: String = ""
    @State private var isDownloadingModel: Bool = false
    @State private var modelError: String?

    @ViewBuilder
    private var builtInModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Current model — with inline Delete button (scoped to this model)
            if !settings.builtInModelId.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.caiSuccess)
                    Text(settings.builtInModelDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                    Button("Delete") {
                        deleteBuiltInModel()
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.8))
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    Spacer()
                }
            }

            // Model picker + download
            HStack(spacing: 8) {
                Picker("", selection: $selectedModelId) {
                    Text("Select a model...").tag("")
                    ForEach(ModelCatalog.curatedModels, id: \.id) { model in
                        Text("\(model.name) (\(model.size))").tag(model.id)
                    }
                    Divider()
                    Text("Other (HuggingFace ID)...").tag(Self.customModelTag)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Model selection")
                .onAppear { selectedModelId = settings.builtInModelId }

                if isDownloadingModel {
                    ProgressView()
                        .scaleEffect(0.6)
                } else if !selectedModelId.isEmpty
                            && selectedModelId != settings.builtInModelId
                            && selectedModelId != Self.customModelTag {
                    Button("Download") {
                        downloadAndSwitchModel(id: selectedModelId)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiPrimary)
                    .buttonStyle(.plain)
                }
            }

            // Custom model input — only shown when "Other" is selected
            if selectedModelId == Self.customModelTag {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.caiSurface.opacity(0.6))
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)
                        TextField("mlx-community/model-name-4bit", text: $customModelId)
                            .font(.system(size: 11))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 8)
                    }
                    .frame(height: 24)

                    if isDownloadingModel {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else if !customModelId.isEmpty {
                        Button("Download") {
                            downloadAndSwitchModel(id: customModelId)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.caiPrimary)
                        .buttonStyle(.plain)
                    }
                }
            }

            // Error display
            if let error = modelError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.caiError)
                    .lineLimit(2)
            }

            HStack(spacing: 0) {
                Text("Powered by MLX on Apple Silicon · ")
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                Button("Browse models") {
                    if let url = URL(string: "https://huggingface.co/mlx-community") {
                        NSWorkspace.shared.open(url)
                        onDismiss?()
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.caiPrimary)
                .buttonStyle(.plain)
            }
        }
    }

    private func downloadAndSwitchModel(id: String) {
        isDownloadingModel = true
        modelError = nil
        Task {
            // Check disk space before attempting download.
            // Use the specific model's size if it's in the curated catalog,
            // otherwise default to a generous 5 GB for unknown custom models.
            let estimatedBytes: Int64 = ModelCatalog.curatedModels
                .first(where: { $0.id == id })
                .flatMap { _ in estimateBytesForCuratedModel(id: id) }
                ?? 5_000_000_000
            let requiredBytes = estimatedBytes + 500_000_000 // model + 500 MB buffer
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
               let available = attrs[.systemFreeSize] as? Int64,
               available < requiredBytes {
                await MainActor.run {
                    isDownloadingModel = false
                    let availStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                    let neededStr = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
                    modelError = "Not enough disk space (\(availStr) available). Need ~\(neededStr)."
                }
                return
            }

            do {
                try await MLXInference.shared.loadModel(id: id)
                await MainActor.run {
                    settings.builtInModelId = id
                    settings.builtInSetupDone = true
                    isDownloadingModel = false
                    customModelId = ""
                    selectedModelId = id
                    modelError = nil
                }
                forceCheckLLMStatus()
            } catch {
                await MainActor.run {
                    isDownloadingModel = false
                    modelError = error.localizedDescription
                }
            }
        }
    }

    private func deleteBuiltInModel() {
        let modelId = settings.builtInModelId
        guard !modelId.isEmpty else { return }

        Task {
            // Unload model first
            await MLXInference.shared.unload()

            // Clear HuggingFace cache for this model
            let sanitizedId = modelId.replacingOccurrences(of: "/", with: "--")
            let cachePath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub/models--\(sanitizedId)")
            if FileManager.default.fileExists(atPath: cachePath.path) {
                try? FileManager.default.removeItem(at: cachePath)
                print("🗑️ Deleted model cache: \(cachePath.path)")
            }

            await MainActor.run {
                settings.builtInSetupDone = false
                settings.builtInModelId = ""
                selectedModelId = ""
            }
            forceCheckLLMStatus()
        }
    }

    /// Estimates download bytes for a curated model by parsing its size string ("~1.8 GB").
    /// Returns nil if the model isn't in the catalog or the size string is unparseable.
    private func estimateBytesForCuratedModel(id: String) -> Int64? {
        guard let model = ModelCatalog.curatedModels.first(where: { $0.id == id }) else {
            return nil
        }
        // Size strings look like "~1.8 GB", "~4.3 GB", "~0.8 GB"
        let cleaned = model.size
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "GB", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let gigabytes = Double(cleaned) else { return nil }
        return Int64(gigabytes * 1_000_000_000)
    }

    // MARK: - Navigation Row

    /// Apple Settings-style navigation row: label + optional count badge + chevron.
    private func navRow(label: String, count: Int = 0, total: Int? = nil, action: (() -> Void)? = nil) -> some View {
        let row = HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.caiTextPrimary)
            Spacer()
            if let total = total {
                Text("\(count)/\(total)")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
            } else if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())

        return Group {
            if let action = action {
                Button(action: action) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
    }

    // MARK: - Connectors Row

    @ObservedObject private var mcpConfigManager = MCPServerConfigManager.shared

    private var connectorsNavRow: some View {
        let configs = mcpConfigManager.serverConfigs
        let configured = configs.filter { config in
            guard config.isEnabled else { return false }
            guard let key = config.authKeychainKey else { return config.authType == .none }
            return KeychainHelper.get(forKey: key) != nil
        }.count
        let total = configs.count

        return navRow(
            label: "Connectors",
            count: configured,
            total: total,
            action: onShowConnectors
        )
    }

    // MARK: - Update Badge

    private var updateBadge: some View {
        Button(action: {
            sparkleUpdater.checkForUpdates()
        }) {
            Text("Check for Updates")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.caiPrimary)
        }
        .buttonStyle(.plain)
        .disabled(!sparkleUpdater.canCheckForUpdates)
        .opacity(sparkleUpdater.canCheckForUpdates ? 1.0 : 0.5)
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
        guard settings.builtInSetupDone, !settings.builtInModelId.isEmpty else { return }

        Task {
            let isLoaded = await MLXInference.shared.isLoaded
            if !isLoaded {
                do {
                    try await MLXInference.shared.loadModel(id: settings.builtInModelId)
                    print("🧠 Built-in MLX model loaded from Settings")
                } catch {
                    print("⚠️ Failed to load MLX model from Settings: \(error.localizedDescription)")
                }
            }
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

    // MARK: - Settings Layout Helpers

    /// Groups multiple settings sections in a rounded-rect container (macOS System Settings style).
    private func settingsGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.caiSurface.opacity(0.3))
            )
        }
    }

    /// Lightweight divider between sections within a group.
    private var settingsDivider: some View {
        Divider().opacity(0.3).padding(.vertical, 8)
    }

    /// Individual settings section with icon + title header.
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
