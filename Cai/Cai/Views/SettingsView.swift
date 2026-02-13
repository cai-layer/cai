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

    /// LLM connection status — checked each time settings opens.
    @State private var llmConnected: Bool? = nil  // nil = checking

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.caiPrimary)
                Text("Settings")
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
                        TextField("https://search.brave.com/search?q=", text: $settings.searchURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .accessibilityLabel("Search engine base URL")
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

                            if settings.modelProvider == .custom {
                                TextField("http://127.0.0.1:8080", text: $settings.customModelURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .accessibilityLabel("Custom model URL")
                            }

                            Text("OpenAI-compatible API endpoint (\(settings.modelURL))")
                                .font(.system(size: 11))
                                .foregroundColor(.caiTextSecondary)
                        }
                        .onChange(of: settings.modelProvider) { _ in forceCheckLLMStatus() }
                        .onChange(of: settings.customModelURL) { _ in forceCheckLLMStatus() }
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

                    // General
                    settingsSection(title: "General", icon: "gearshape") {
                        Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                            .font(.system(size: 12))
                            .foregroundColor(.caiTextPrimary)
                            .accessibilityLabel("Launch Cai at login")
                    }

                    // Hotkey reminder
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                        Text("Press \u{2325}C to trigger Cai anywhere")
                            .font(.system(size: 11))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .onAppear {
            permissions.checkAccessibilityPermission()
            checkLLMStatus()
        }
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
