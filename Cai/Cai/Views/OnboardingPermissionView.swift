import SwiftUI

/// Friendly onboarding window shown on first launch when Accessibility permission
/// is not yet granted. Auto-dismisses once the user enables the permission.
struct OnboardingPermissionView: View {
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            // Logo
            CaiLogoShape()
                .fill(Color.caiPrimary)
                .frame(width: 48, height: 48 * (127.0 / 217.0))
                .padding(.bottom, 16)

            Text("Welcome to Cai")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            Spacer().frame(height: 12)

            Text("Cai needs **Accessibility permission** to enable the ⌥C hotkey.")
                .font(.system(size: 13))
                .foregroundColor(.caiTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer().frame(height: 20)

            // What it does
            VStack(alignment: .leading, spacing: 8) {
                permissionRow(icon: "keyboard", text: "Register the global ⌥C shortcut")
                permissionRow(icon: "doc.on.clipboard", text: "Simulate ⌘C to copy your selection")
            }
            .padding(.horizontal, 32)

            Spacer().frame(height: 24)

            Button(action: {
                permissions.openAccessibilityPreferences()
            }) {
                Text("Open System Settings")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.caiPrimary)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 32)

            Spacer().frame(height: 10)

            Text("You can also find this in\nSystem Settings → Privacy & Security → Accessibility")
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary.opacity(0.6))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 20)
        }
        .frame(width: 320, height: 340)
        .background(VisualEffectBackground(cornerRadius: 0))
    }

    private func permissionRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.caiPrimary)
                .frame(width: 20, alignment: .center)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.caiTextPrimary)
        }
    }
}
