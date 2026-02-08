import SwiftUI

/// Settings panel — used both inline in the action window (via Cai logo)
/// and in the menu bar popover. Adapts to parent's size constraints.
struct SettingsView: View {
    @ObservedObject var settings = CaiSettings.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    /// Optional callback to navigate to shortcuts management (only available
    /// when rendered inside ActionListWindow, not the menu bar popover).
    var onShowShortcuts: (() -> Void)? = nil

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
                    }

                    // Custom Shortcuts
                    settingsSection(title: "Custom Shortcuts", icon: "bolt.circle.fill") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let onShowShortcuts = onShowShortcuts {
                                Button(action: onShowShortcuts) {
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
                                .buttonStyle(.plain)
                            } else {
                                Text(settings.shortcuts.isEmpty
                                     ? "No shortcuts configured"
                                     : "\(settings.shortcuts.count) shortcut\(settings.shortcuts.count == 1 ? "" : "s") configured")
                                    .font(.system(size: 12))
                                    .foregroundColor(.caiTextSecondary)
                            }
                            Text("Type to search shortcuts when Cai is open")
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
