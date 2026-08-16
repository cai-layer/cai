import SwiftUI

/// The **System Access** tab of `MCPManagementView` (the "Connections" screen):
/// the on-demand macOS privacy (TCC) grants an action may read from — Calendar
/// and Contacts today. Posture "B — Shortcuts-modeled, chain-intact"; see
/// `NativeAccessManager` and `_docs/architecture/PERMISSIONS.md`.
///
/// Lives here, alongside Tools and Agents, because to a user those three tabs
/// answer one question — "what can Cai reach?" — even though they are
/// mechanically different (outbound tools, inbound agents, OS grants). Grants
/// used to sit inside the Destinations screen; the Settings IA pass (Option A)
/// moved them here so Destinations means outputs only.
///
/// Chromeless like `ConnectorsSettingsView`: the parent `ManagementScreen`
/// owns the header/footer.
struct NativeAccessSettingsView: View {
    @ObservedObject var nativeAccess = NativeAccessManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text("Let actions read from these apps. macOS asks the first time you use one; you can change it anytime in System Settings.")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                ForEach(NativeAccessManager.Domain.allCases) { domain in
                    nativeAccessRow(domain)
                        .padding(.horizontal, 12)
                }

                Text("If denied, re-enable in System Settings → Privacy & Security.")
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            WindowController.acceptsFilterInput = false
            // Grants can change out-of-band (System Settings, another app), so
            // re-read the live TCC status each time this tab opens.
            nativeAccess.refreshAll()
        }
    }

    /// A single TCC-domain toggle row. Same visual vocabulary as the
    /// destination/connector rows (20pt-frame leading icon + label + subtitle +
    /// indigo switch) so the tabs read as one system. The subtitle carries live
    /// status so a denied grant explains itself instead of silently reading OFF.
    private func nativeAccessRow(_ domain: NativeAccessManager.Domain) -> some View {
        let state = nativeAccess.state(for: domain)
        let isOn = state.isOn

        return HStack(spacing: 10) {
            Image(systemName: domain.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isOn ? .caiPrimary : .caiTextSecondary.opacity(0.5))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(domain.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                Text(nativeAccessSubtitle(domain: domain, state: state))
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
            }

            Spacer()

            // The toggle reflects `isOn`; the flip is a request-or-guide intent,
            // not a direct write (macOS owns the real state). `handleToggle`
            // decides based on the current state — prompt when undetermined,
            // open System Settings otherwise.
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { _ in nativeAccess.handleToggle(for: domain) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.caiPrimary)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.caiSurface.opacity(0.3))
        )
    }

    /// Status-aware subtitle: the benefit line when grantable, an explanatory
    /// line when the OS has blocked it (so the OFF toggle isn't a dead end).
    private func nativeAccessSubtitle(domain: NativeAccessManager.Domain, state: NativeAccessManager.AccessState) -> String {
        switch state {
        case .notDetermined, .authorized:
            return domain.subtitle
        case .denied:
            return "Denied — re-enable in System Settings"
        case .restricted:
            return "Restricted by your organization"
        }
    }
}
