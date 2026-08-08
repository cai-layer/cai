import CaiActionCore
import SwiftUI

/// Settings → Secrets. A quiet list with a guarded add flow — the design risk
/// budget went to exactly two places (mono names, the shell import); everything
/// else is the house pattern. See `_docs/architecture/SECRETS.md`.
///
/// Write-only: a value can be saved, replaced and deleted, and is never
/// rendered again anywhere in this screen, whatever the state.
struct SecretsManagementView: View {
    let onBack: () -> Void

    /// Single-list screen: no tabs, but `ManagementScreen` stays generic.
    private enum SecretsTab { case main }
    @State private var tab: SecretsTab = .main

    private enum Mode: Equatable {
        case list
        /// `replacing` carries the locked name for Replace Value….
        case form(replacing: String?)
        case importing
    }
    @State private var mode: Mode = .list

    @State private var listResult: SecretStore.ListResult = .items([])
    @State private var usageCounts: [String: Int] = [:]
    /// Transient "Saved in Keychain" line (the Connectors grammar).
    @State private var confirmation: String?
    /// Set when a Keychain delete is refused (locked keychain, denied ACL): the
    /// row survives `refresh()`, so without this the delete just "doesn't take".
    @State private var deleteFailure: String?
    @State private var pendingDelete: SecretDescriptor?

    /// The router's `handleEsc` consults this before leaving the screen, so
    /// Esc closes an open form first and backs out of the screen second
    /// (the `MCPFormView.pickerDropdownOpen` precedent).
    static var escInterceptor: (() -> Bool)?

    var body: some View {
        ManagementScreen(
            icon: "key.fill",
            title: "Secrets",
            subtitle: "Stored in your Mac's Keychain",
            tabs: [],
            selection: $tab,
            customTabId: nil,
            onAdd: mode == .list ? { enterForm(replacing: nil) } : nil
        ) {
            switch mode {
            case .list:
                listContent
            case .form(let replacing):
                SecretFormView(
                    replacingName: replacing,
                    existingNames: Set(secrets.map(\.name)),
                    onSaved: { name, replaced in
                        leaveSubScreen(confirming: replaced ? "\(name) replaced in Keychain" : "Saved in Keychain")
                    },
                    onCancel: { leaveSubScreen(confirming: nil) },
                    onImportInstead: { enterImport() }
                )
            case .importing:
                ShellImportView(
                    onDone: { saved in
                        leaveSubScreen(confirming: saved == 0 ? nil : "\(saved) secret\(saved == 1 ? "" : "s") saved in Keychain")
                    },
                    onCancel: { leaveSubScreen(confirming: nil) },
                    onAddManually: { enterForm(replacing: nil) }
                )
            }
        }
        .onAppear {
            refresh()
            Self.escInterceptor = { escPressed() }
        }
        .onDisappear {
            Self.escInterceptor = nil
            WindowController.passThrough = false
        }
        .alert(deleteTitle, isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let doomed = pendingDelete { delete(doomed) }
            }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - List

    private var secrets: [SecretDescriptor] {
        if case .items(let items) = listResult { return items }
        return []
    }

    @ViewBuilder
    private var listContent: some View {
        switch listResult {
        case .unavailable:
            // Never the empty state: "No secrets yet" over a locked keychain
            // invites the user to overwrite every secret they own.
            keychainUnavailableBanner
        case .items(let items) where items.isEmpty:
            emptyState
        case .items(let items):
            ScrollView {
                VStack(spacing: 6) {
                    if let deleteFailure {
                        deleteFailureLine(deleteFailure)
                    }
                    if let confirmation {
                        confirmationLine(confirmation)
                    }
                    ForEach(items) { secret in
                        secretRow(secret)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func secretRow(_ secret: SecretDescriptor) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiTextSecondary.opacity(0.5))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                // SF Mono: the name is the exact string used in
                // {{secrets.…}}, and O/0 must be distinguishable (DESIGN.md).
                Text(secret.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.caiTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(secret.name)
                Text(subtitle(for: secret))
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .monospacedDigit()
            }

            Spacer()

            Menu {
                Button(action: { enterForm(replacing: secret.name) }) {
                    Label("Replace Value…", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Button(role: .destructive, action: { pendingDelete = secret }) {
                    Label("Delete…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.caiSurface.opacity(0.3))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(secret.name), \(subtitle(for: secret))")
    }

    private func subtitle(for secret: SecretDescriptor) -> String {
        var parts: [String] = []
        if let created = secret.created {
            parts.append("Added \(created.formatted(.dateTime.day().month()))")
        }
        let uses = usageCounts[secret.name] ?? 0
        parts.append(uses == 0 ? "Not used yet" : "Used by \(uses) action\(uses == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        ManagementEmptyState(
            icon: "key",
            title: "No secrets yet",
            description: "Actions reference it by name and Cai hands it only to the command that runs.",
            ctaLabel: "Add a Secret",
            ctaIcon: "plus",
            ctaAction: { enterForm(replacing: nil) },
            secondaryCtaLabel: "Import from Shell…",
            secondaryCtaIcon: "terminal",
            secondaryCtaAction: { enterImport() }
        )
        .frame(maxHeight: .infinity)
    }

    private var keychainUnavailableBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiError)
            Text("Cai can't read the Keychain right now. Unlock it and reopen this screen.")
                .font(.system(size: 12))
                .foregroundColor(.caiTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.caiSurface.opacity(0.3))
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func confirmationLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.caiSuccess)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
            Spacer()
        }
        .task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.2)) { confirmation = nil }
        }
    }

    private func deleteFailureLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.caiError)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.caiTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeOut(duration: 0.2)) { deleteFailure = nil }
        }
    }

    // MARK: - Delete

    private var deleteTitle: String {
        "Delete \(pendingDelete?.name ?? "")?"
    }

    private var deleteMessage: String {
        guard let doomed = pendingDelete else { return "" }
        let affected = SecretUsage.actionNames(referencing: doomed.name)
        guard !affected.isEmpty else {
            return "This can't be undone. The value is not recoverable."
        }
        let shown = affected.prefix(3).joined(separator: ", ")
        let more = affected.count > 3 ? " +\(affected.count - 3) more" : ""
        let noun = affected.count == 1 ? "action uses" : "actions use"
        return "\(affected.count) \(noun) it and will fail until you re-add it: \(shown)\(more)."
    }

    private func delete(_ secret: SecretDescriptor) {
        let deleted = SecretStore.delete(secret.name)
        pendingDelete = nil
        refresh()
        if deleted { ActionsSnapshotPublisher.shared.publishNow() }
        // The row disappearing is the confirmation; no toast. A refused delete
        // leaves the row, so say why instead of letting it look like a no-op.
        if !deleted {
            confirmation = nil
            deleteFailure = "\(secret.name) couldn't be deleted from the Keychain."
        }
    }

    // MARK: - Navigation

    private func enterForm(replacing: String?) {
        confirmation = nil
        WindowController.passThrough = true  // CAI-22
        withAnimation(.easeInOut(duration: 0.15)) { mode = .form(replacing: replacing) }
    }

    private func enterImport() {
        confirmation = nil
        WindowController.passThrough = true  // CAI-22: the candidate list has no
        // text field, but the flow can bounce into the form via "Add manually".
        withAnimation(.easeInOut(duration: 0.15)) { mode = .importing }
    }

    private func leaveSubScreen(confirming message: String?) {
        WindowController.passThrough = false  // CAI-22
        refresh()
        // A save/replace/import may have changed the secret names; republish so
        // the agent snapshot lists them (a no-op rewrite after a plain cancel).
        ActionsSnapshotPublisher.shared.publishNow()
        confirmation = message
        withAnimation(.easeInOut(duration: 0.15)) { mode = .list }
    }

    /// True when Esc was consumed internally (a sub-screen was open).
    private func escPressed() -> Bool {
        guard mode != .list else { return false }
        leaveSubScreen(confirming: nil)
        return true
    }

    private func refresh() {
        deleteFailure = nil
        listResult = SecretStore.enumerate()
        usageCounts = SecretUsage.counts()
    }
}

// MARK: - Usage scanning

/// Where each secret is referenced, per the advisory scanner. Powers the row
/// subtitles ("Used by 2 actions") and the delete confirmation's list of
/// what breaks. Advisory means over-reporting is acceptable; execution never
/// consults this.
enum SecretUsage {

    /// Reference counts by secret name across shortcuts and destinations.
    static func counts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for template in templates() {
            for name in SecretReference.names(in: template.text) {
                counts[name, default: 0] += 1
            }
        }
        return counts
    }

    /// Names of the actions/destinations whose templates reference `name`.
    static func actionNames(referencing name: String) -> [String] {
        templates()
            .filter { SecretReference.names(in: $0.text).contains(name) }
            .map(\.owner)
    }

    private static func templates() -> [(owner: String, text: String)] {
        var found: [(String, String)] = []
        for shortcut in CaiSettings.shared.shortcuts {
            found.append((shortcut.name, shortcut.value))
        }
        // Destinations keep their templates in kind-specific config; encoding
        // the whole definition and scanning that is what keeps this correct
        // when a new template-bearing field is added.
        let encoder = JSONEncoder()
        for destination in CaiSettings.shared.outputDestinations {
            if let data = try? encoder.encode(destination),
               let json = String(data: data, encoding: .utf8) {
                found.append((destination.name, json))
            }
        }
        return found
    }
}
