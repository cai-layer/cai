import SwiftUI

/// Settings sub-view for managing MCP server connections (GitHub, Linear, etc.).
/// Shows configured servers with status indicators, API key entry, and test connection.
/// Follows the same push-navigation pattern as DestinationsManagementView.
struct ConnectorsSettingsView: View {
    @ObservedObject var configManager = MCPConfigManager.shared
    let onBack: () -> Void

    @State private var editingServerId: UUID?
    @State private var apiKeyInputs: [UUID: String] = [:]  // Temp input state per server
    @State private var testingServer: UUID?
    @State private var testResult: (UUID, Bool, String)?  // (serverId, success, message)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Connectors")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)

                Spacer()

                connectorStatusSummary
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.caiDivider)

            // Content
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(configManager.serverConfigs) { config in
                        serverCard(config)
                    }

                    if configManager.serverConfigs.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 24))
                                .foregroundColor(.caiTextSecondary.opacity(0.3))
                            Text("No connectors configured")
                                .font(.system(size: 12))
                                .foregroundColor(.caiTextSecondary.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }

                    // Info text
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connectors let Cai create issues, tickets, and more via MCP servers.")
                            .font(.system(size: 10))
                            .foregroundColor(.caiTextSecondary.opacity(0.5))
                        Text("Config: ~/.config/cai/mcp-servers.json")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.caiTextSecondary.opacity(0.3))
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
                .padding(16)
            }

            Spacer(minLength: 0)

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onAppear {
            WindowController.acceptsFilterInput = false
            // Pre-populate API key inputs with masked state
            for config in configManager.serverConfigs {
                if let key = config.authKeychainKey, KeychainHelper.get(forKey: key) != nil {
                    apiKeyInputs[config.id] = "••••••••"
                } else {
                    apiKeyInputs[config.id] = ""
                }
            }
        }
    }

    // MARK: - Status Summary

    private var connectorStatusSummary: some View {
        let configured = configManager.serverConfigs.filter { config in
            guard config.isEnabled else { return false }
            guard let key = config.authKeychainKey else { return config.authType == .none }
            return KeychainHelper.get(forKey: key) != nil
        }.count
        let total = configManager.serverConfigs.count

        return Group {
            if total > 0 {
                Text("\(configured)/\(total)")
                    .font(.system(size: 11))
                    .foregroundColor(configured > 0 ? .green : .caiTextSecondary)
            }
        }
    }

    // MARK: - Server Card

    private func serverCard(_ config: MCPServerConfig) -> some View {
        let status = configManager.serverStatuses[config.id] ?? .disconnected
        let isEditing = editingServerId == config.id

        return VStack(alignment: .leading, spacing: 0) {
            // Server header row
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isEditing {
                        editingServerId = nil
                    } else {
                        editingServerId = config.id
                    }
                }
            }) {
                HStack(spacing: 10) {
                    connectorIcon(for: config.providerType, isConnected: status.isConnected)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(config.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.caiTextPrimary)

                        Text(status.displayText)
                            .font(.system(size: 10))
                            .foregroundColor(statusColor(status))
                    }

                    Spacer()

                    // Enable/disable toggle
                    Toggle("", isOn: Binding(
                        get: { config.isEnabled },
                        set: { newValue in
                            var updated = config
                            updated.isEnabled = newValue
                            configManager.updateServer(updated)
                            if !newValue {
                                Task { await MCPClientService.shared.disconnect(configId: config.id) }
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.caiPrimary)
                    .labelsHidden()

                    Image(systemName: isEditing ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isEditing {
                serverDetail(config, status: status)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.caiSurface.opacity(0.3))
        )
    }

    // MARK: - Server Detail (Expanded)

    private func serverDetail(_ config: MCPServerConfig, status: MCPServerStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.3).padding(.horizontal, 8)

            // URL (read-only display)
            if let url = config.transport.url {
                HStack(spacing: 6) {
                    Text("Endpoint")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.caiTextSecondary)
                    Spacer()
                    Text(url)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.caiTextSecondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // API Key
            if config.authType == .bearerToken {
                apiKeySection(config)
            }



            // Test connection button
            HStack(spacing: 8) {
                Button(action: { testConnection(config) }) {
                    HStack(spacing: 4) {
                        if testingServer == config.id {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                        }
                        Text("Test Connection")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.caiPrimary)
                }
                .buttonStyle(.plain)
                .disabled(testingServer == config.id)

                if status.isConnected {
                    Button(action: {
                        Task { await MCPClientService.shared.disconnect(configId: config.id) }
                    }) {
                        Text("Disconnect")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Test result (only show success — errors already shown in header status)
                if let result = testResult, result.0 == config.id, result.1 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text(result.2)
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                }
            }

            // Connected tools info
            if case .connected(let toolCount) = status {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 9))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                    Text("\(toolCount) tools available")
                        .font(.system(size: 10))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: - API Key Section

    private func apiKeySection(_ config: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(apiKeyLabel(for: config))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.caiTextSecondary)

            HStack(spacing: 8) {
                SecureField(apiKeyPlaceholder(for: config), text: Binding(
                    get: { apiKeyInputs[config.id] ?? "" },
                    set: { apiKeyInputs[config.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onAppear {
                    WindowController.passThrough = true
                }
                .onDisappear {
                    WindowController.passThrough = false
                }

                Button(action: { saveAPIKey(for: config) }) {
                    Text("Save")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.caiPrimary)
                }
                .buttonStyle(.plain)
            }

            if let key = config.authKeychainKey, KeychainHelper.get(forKey: key) != nil {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                    Text("Key saved in Keychain")
                        .font(.system(size: 9))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                }
            }

            Button(action: {
                if let url = URL(string: tokenHelpURL(for: config)) {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 3) {
                    Text("Get token")
                        .font(.system(size: 9))
                        .foregroundColor(.caiPrimary)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.caiPrimary.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func connectorIcon(for providerType: MCPProviderType, isConnected: Bool) -> some View {
        let color: Color = isConnected ? .caiPrimary : .caiTextSecondary
        switch providerType {
        case .github:
            GitHubIcon(color: color)
                .frame(width: 14, height: 14)
        case .linear:
            LinearIcon(color: color)
                .frame(width: 14, height: 14)
        case .custom:
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(color)
        }
    }

    private func statusColor(_ status: MCPServerStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .caiTextSecondary.opacity(0.5)
        }
    }

    private func tokenHelpURL(for config: MCPServerConfig) -> String {
        switch config.providerType {
        case .github: return "https://getcai.app/docs/usage/connectors/#github"
        case .linear: return "https://getcai.app/docs/usage/connectors/#linear"
        case .custom: return "https://getcai.app/docs/"
        }
    }

    private func apiKeyLabel(for config: MCPServerConfig) -> String {
        switch config.providerType {
        case .github: return "GitHub Personal Access Token"
        case .linear: return "Linear API Key"
        case .custom: return "API Key"
        }
    }

    private func apiKeyPlaceholder(for config: MCPServerConfig) -> String {
        switch config.providerType {
        case .github: return "ghp_..."
        case .linear: return "lin_api_..."
        case .custom: return "Enter API key"
        }
    }

    private func saveAPIKey(for config: MCPServerConfig) {
        guard let keychainKey = config.authKeychainKey else { return }
        let input = apiKeyInputs[config.id] ?? ""
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Don't save the masked placeholder
        guard !trimmed.isEmpty, trimmed != "••••••••" else { return }

        KeychainHelper.set(trimmed, forKey: keychainKey)
        apiKeyInputs[config.id] = "••••••••"
    }

    private func testConnection(_ config: MCPServerConfig) {
        testingServer = config.id
        testResult = nil

        Task {
            do {
                try await MCPClientService.shared.connect(config: config)
                let status = await MCPClientService.shared.status(for: config.id)
                let toolCount: Int
                if case .connected(let count) = status {
                    toolCount = count
                } else {
                    toolCount = 0
                }

                await MainActor.run {
                    testingServer = nil
                    testResult = (config.id, true, "\(toolCount) tools")
                }
            } catch {
                await MainActor.run {
                    testingServer = nil
                    testResult = (config.id, false, error.localizedDescription)
                }
            }
        }
    }
}
