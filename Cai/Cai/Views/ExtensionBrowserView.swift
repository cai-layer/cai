import SwiftUI

/// Browse and install community extensions from the curated repo.
/// Follows the same layout pattern as ShortcutsManagementView.
struct ExtensionBrowserView: View {
    @ObservedObject var settings = CaiSettings.shared
    let onBack: () -> Void

    @State private var entries: [ExtensionService.ExtensionEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var installingSlug: String?

    // Shell confirmation
    @State private var shellConfirmSlug: String?
    @State private var shellConfirmCommand: String = ""
    @State private var shellConfirmName: String = ""

    private var displayedEntries: [ExtensionService.ExtensionEntry] {
        guard !searchText.isEmpty else { return entries }
        let query = searchText.lowercased()
        return entries.filter {
            $0.name.lowercased().contains(query) ||
            $0.description.lowercased().contains(query) ||
            $0.tags.contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.caiPrimary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Extensions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.caiTextPrimary)

                    Text("Browse community extensions")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.caiDivider)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary.opacity(0.5))
                TextField("Search extensions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.caiSurface.opacity(0.4))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Content
            ScrollView {
                VStack(spacing: 4) {
                    if isLoading {
                        loadingState
                    } else if let error = errorMessage {
                        errorState(error)
                    } else if displayedEntries.isEmpty {
                        emptyState
                    } else {
                        ForEach(displayedEntries) { entry in
                            extensionRow(entry)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            Divider()
                .background(Color.caiDivider)

            // Footer
            HStack(spacing: 12) {
                KeyboardHint(key: "Esc", label: "Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .task { await loadExtensions() }
        .alert("Install Shell Command", isPresented: Binding(
            get: { shellConfirmSlug != nil },
            set: { if !$0 { shellConfirmSlug = nil } }
        )) {
            Button("Cancel", role: .cancel) { shellConfirmSlug = nil }
            Button("Install") {
                if let slug = shellConfirmSlug {
                    confirmShellInstall(slug: slug, name: shellConfirmName, command: shellConfirmCommand)
                }
            }
        } message: {
            Text("This extension will run the following command on your clipboard text:\n\n\(shellConfirmCommand)")
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading extensions...")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding()
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 28))
                .foregroundColor(.caiTextSecondary.opacity(0.4))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await loadExtensions() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.caiPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No extensions match your search")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding()
    }

    // MARK: - Extension Row

    private func extensionRow(_ entry: ExtensionService.ExtensionEntry) -> some View {
        let isInstalled = settings.installedExtensions.contains(entry.slug)
        let isInstalling = installingSlug == entry.slug

        return HStack(spacing: 10) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.caiSurface.opacity(0.6))
                    .frame(width: 28, height: 28)

                Image(systemName: entry.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
            }

            // Name + description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                        .lineLimit(1)

                    Text(entry.type.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.caiTextSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.caiSurface.opacity(0.8))
                        .cornerRadius(3)
                }

                Text(entry.description)
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Install button
            if isInstalling {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 60)
            } else {
                Button(isInstalled ? "Installed" : "Install") {
                    if isInstalled {
                        uninstallExtension(entry)
                    } else {
                        Task { await installExtension(entry) }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isInstalled ? .caiTextSecondary : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isInstalled ? Color.caiSurface.opacity(0.6) : Color.caiPrimary)
                .cornerRadius(5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.caiSurface.opacity(0.3))
        .cornerRadius(8)
    }

    // MARK: - Load

    private func loadExtensions() async {
        isLoading = true
        errorMessage = nil
        do {
            entries = try await ExtensionService.fetchIndex()
            isLoading = false
        } catch {
            #if DEBUG
            print("[ExtensionBrowser] Load failed: \(error)")
            #endif
            errorMessage = "Could not load extensions"
            isLoading = false
        }
    }

    // MARK: - Install

    private func installExtension(_ entry: ExtensionService.ExtensionEntry) async {
        installingSlug = entry.slug
        defer { installingSlug = nil }

        do {
            let yaml = try await ExtensionService.fetchYAML(slug: entry.slug)

            // Shell: show confirmation alert before installing
            if entry.type == "shell" {
                let parsed = try ExtensionParser.parse(yaml, allowShell: true)
                if case .shortcut(let sc, _, _) = parsed {
                    await MainActor.run {
                        shellConfirmName = sc.name
                        shellConfirmCommand = sc.value
                        shellConfirmSlug = entry.slug
                    }
                }
                return
            }

            let parsed = try ExtensionParser.parse(yaml, allowShell: false)
            await MainActor.run {
                saveParsedExtension(parsed, slug: entry.slug)
            }
        } catch {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .caiShowToast, object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }
    }

    private func confirmShellInstall(slug: String, name: String, command: String) {
        let shortcut = CaiShortcut(name: name, type: .shell, value: command)
        settings.shortcuts.append(shortcut)
        settings.installedExtensions.insert(slug)
        shellConfirmSlug = nil
    }

    private func saveParsedExtension(_ parsed: ExtensionParser.ParsedExtension, slug: String) {
        switch parsed {
        case .shortcut(let shortcut, _, _):
            // Avoid duplicates by name
            if !settings.shortcuts.contains(where: { $0.name == shortcut.name }) {
                settings.shortcuts.append(shortcut)
            }
        case .destination(let destination, _, _):
            if !settings.outputDestinations.contains(where: { $0.name == destination.name }) {
                settings.outputDestinations.append(destination)
            }
        }
        settings.installedExtensions.insert(slug)
    }

    // MARK: - Uninstall

    private func uninstallExtension(_ entry: ExtensionService.ExtensionEntry) {
        // Remove shortcut or destination by matching name
        settings.shortcuts.removeAll { $0.name == entry.name }
        settings.outputDestinations.removeAll { $0.name == entry.name }
        settings.installedExtensions.remove(entry.slug)
    }
}
