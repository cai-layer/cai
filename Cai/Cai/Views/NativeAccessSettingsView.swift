import SwiftUI

/// The **System Access** tab of `MCPManagementView` (the "Connections" screen):
/// the single answer to "what can Cai touch on my Mac?" Two groups, because the
/// rows are two different species and a uniform list would imply otherwise:
///
/// - **App data actions can use** — the on-demand TCC grants Cai can request
///   (Calendar, Reminders, Contacts). Toggles; flipping fires the real OS prompt.
/// - **Managed by macOS** — grants Cai can report on but never request
///   (Accessibility, Automation). Status text plus an "Open" deep link, no
///   toggle. The header doubles as the answer to "why can't I flip this."
///
/// Posture "B — Shortcuts-modeled, chain-intact"; see `NativeAccessManager`,
/// `NativeAccessManager.SystemDomain` and `_docs/architecture/PERMISSIONS.md`.
///
/// Lives here, alongside Tools and Agents, because to a user those three tabs
/// answer one question — "what can Cai reach?" — even though they are
/// mechanically different (outbound tools, inbound agents, OS grants). Before
/// the "Complete System Access" change the answer was split three ways: these
/// toggles, the header shield (Accessibility) and a footnote on the Destinations
/// screen (Automation). Both of those now point here.
///
/// Chromeless like `ConnectorsSettingsView`: the parent `ManagementScreen`
/// owns the header/footer.
struct NativeAccessSettingsView: View {
    @ObservedObject var nativeAccess = NativeAccessManager.shared
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                grantableGroup
                systemGroup
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            WindowController.acceptsFilterInput = false
            // Grants can change out-of-band (System Settings, another app), so
            // re-read live status each time this tab opens. The Accessibility
            // poller only runs during onboarding, so it needs an explicit read.
            nativeAccess.refreshAll()
            permissions.checkAccessibilityPermission()
        }
    }

    // MARK: - Groups

    private var grantableGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            groupHeader("App data actions can use")

            Text("macOS asks the first time an action needs one. You can change these anytime in System Settings.")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)

            ForEach(NativeAccessManager.Domain.allCases) { domain in
                grantableRow(domain)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var systemGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            groupHeader("Managed by macOS")

            ForEach(NativeAccessManager.SystemDomain.allCases) { domain in
                systemRow(domain)
                    .padding(.horizontal, 12)
            }
        }
    }

    /// Group label, matching `SettingsView.settingsGroup`'s treatment so the
    /// two screens don't fork their vocabulary.
    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(.caiTextSecondary.opacity(0.5))
            .padding(.horizontal, 16)
    }

    // MARK: - Rows

    /// A grantable TCC-domain toggle row. Same visual vocabulary as the
    /// destination/connector rows (20pt-frame leading icon + label + subtitle +
    /// indigo switch) so the tabs read as one system. The subtitle carries live
    /// status so a denied grant explains itself instead of silently reading OFF.
    private func grantableRow(_ domain: NativeAccessManager.Domain) -> some View {
        let state = nativeAccess.state(for: domain)
        let isOn = state.isOn

        return rowShell(
            icon: domain.icon,
            iconActive: isOn,
            title: domain.title,
            subtitle: grantableSubtitle(domain: domain, state: state)
        ) {
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
            .accessibilityLabel("\(domain.title) access")
        }
    }

    /// A read-only row for a grant Cai can't request. Trailing edge is status
    /// text plus a neutral "Open" button — never a toggle (there is nothing to
    /// flip) and never indigo (nothing here acts in-app; DESIGN.md's indigo
    /// discipline reserves the accent for things that do something).
    ///
    /// The status text stays `caiTextSecondary`: the header shield already
    /// carries the green/orange semantic for Accessibility, and a second
    /// coloured element on the same journey is decoration.
    private func systemRow(_ domain: NativeAccessManager.SystemDomain) -> some View {
        let status = domain.statusText(
            accessibilityGranted: permissions.hasAccessibilityPermission
        )

        return rowShell(
            icon: domain.icon,
            iconActive: false,
            title: domain.title,
            subtitle: domain.subtitle
        ) {
            HStack(spacing: 8) {
                // `nil` for Automation: an app-level word in the slot where
                // "Granted" appears would read as a status Cai verified.
                if let status {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                }

                Button(action: { NSWorkspace.shared.open(domain.settingsURL) }) {
                    HStack(spacing: 3) {
                        Text("Open")
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                }
                .buttonStyle(.plain)
                .help(domain == .automation
                      ? "See per-app grants in System Settings"
                      : "Open \(domain.title) in System Settings")
                .accessibilityLabel("Open \(domain.title) in System Settings")
            }
        }
    }

    /// The shared row chrome both kinds use, so the groups differ by header and
    /// trailing edge only — not by texture.
    private func rowShell<Trailing: View>(
        icon: String,
        iconActive: Bool,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(iconActive ? .caiPrimary : .caiTextSecondary.opacity(0.5))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            trailing()
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
    private func grantableSubtitle(domain: NativeAccessManager.Domain, state: NativeAccessManager.AccessState) -> String {
        switch state {
        case .notDetermined, .authorized:
            return domain.subtitle
        case .denied:
            return "Denied. Re-enable in System Settings."
        case .restricted:
            return "Restricted by your organization."
        }
    }
}
