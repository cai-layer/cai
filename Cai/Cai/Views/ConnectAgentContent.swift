import SwiftUI

/// The Server half of MCP: agents that reach into Cai to propose actions.
///
/// Renders without chrome; `MCPManagementView` owns the header and footer.
///
/// The kill switch comes first because it is the promise everything below
/// depends on. The rest of the screen is "paste this somewhere"; the switch is
/// "and nothing it sends can run until you approve it".
struct ConnectAgentContent: View {

    @ObservedObject private var settings = CaiSettings.shared

    @State private var selectedClient: AgentClient = .claudeCode
    /// Set for a beat after copying, so the button confirms rather than leaving
    /// the user wondering whether the click registered.
    @State private var copied = false
    /// True when the helper symlink is absent even after a repair attempt.
    /// The snippet is withheld then: a copied path that points at nothing
    /// fails invisibly inside the user's agent.
    @State private var helperMissing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                killSwitchRow

                if settings.allowAgentProposals, helperMissing {
                    helperMissingRow
                } else if settings.allowAgentProposals {
                    Picker("", selection: $selectedClient) {
                        ForEach(AgentClient.allCases) { client in
                            Text(client.label).tag(client)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Agent to connect")

                    Text(selectedClient.instruction)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Cursor leads with the deeplink, because for that one
                    // client the whole job really is one click. The JSON stays
                    // underneath as the fallback for anyone whose Cursor does
                    // not take the scheme.
                    if selectedClient == .cursor, let installURL = AgentConnection.cursorInstallURL() {
                        Button(AgentConnection.cursorButtonTitle) {
                            NSWorkspace.shared.open(installURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.caiPrimary)
                        .controlSize(.small)
                        .help("Opens Cursor and adds Cai for you")

                        Text(AgentConnection.cursorFallbackCaption)
                            .font(.system(size: 10))
                            .foregroundColor(.caiTextSecondary.opacity(0.7))
                    }

                    snippetField
                } else {
                    Text(AgentConnection.disabledCaption)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .onAppear(perform: verifyHelper)
        .onChange(of: settings.allowAgentProposals) { enabled in
            if enabled { verifyHelper() }
        }
    }

    /// Repairs the symlink the way launch does, then checks whether the path
    /// every snippet names actually resolves. `fileExists` follows symlinks,
    /// so a dangling link counts as missing.
    private func verifyHelper() {
        HelperInstaller.refreshSymlink()
        helperMissing = !FileManager.default.fileExists(atPath: AgentConnection.helperPath())
    }

    private var helperMissingRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
            Text(AgentConnection.helperMissingCaption)
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var killSwitchRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentConnection.killSwitchTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextPrimary)
                Text(AgentConnection.killSwitchCaption)
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $settings.allowAgentProposals)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.caiPrimary)
                .labelsHidden()
                .accessibilityLabel(AgentConnection.killSwitchTitle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.caiSurface.opacity(0.3)))
    }

    /// The command or config, with copy as the primary action: this is a value
    /// to take elsewhere, so reading it is secondary to copying it.
    private var snippetField: some View {
        let snippet = AgentConnection.snippet(for: selectedClient)

        return HStack(alignment: .top, spacing: 8) {
            Text(snippet)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.caiTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(copied ? AgentConnection.copiedButtonTitle : AgentConnection.copyButtonTitle) {
                copy(snippet)
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.plain)
            .foregroundColor(.caiPrimary)
            // Sized for the longer of the two labels. Without this, "Copy"
            // becoming "Copied" widens the button and shoves the snippet
            // sideways for the second and a half it takes to change back.
            .frame(width: 44, alignment: .trailing)
            .accessibilityLabel("Copy the \(selectedClient.label) command")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.caiSurface.opacity(0.5)))
    }

    private func copy(_ snippet: String) {
        // Through the serial queue like every other pasteboard write, so it
        // cannot interleave with a paste-back snapshot and cost the user their
        // clipboard (CAI-01).
        PasteboardQueue.shared.write {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet, forType: .string)
            // Confirm from inside the queued block: if the queue is busy
            // draining a paste-back, "Copied" must not show while the
            // pasteboard still holds the old contents.
            DispatchQueue.main.async {
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            }
        }
    }
}
