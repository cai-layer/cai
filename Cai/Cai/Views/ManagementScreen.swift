import SwiftUI

/// Generic two-tab management container — the parent shell that
/// `ActionsManagementView` and `DestinationsManagementView` both compose.
///
/// Owns the parts that were duplicated across both screens before:
/// - Header (icon · title · subtitle on the left, optional `+` on the right)
/// - TabBar (Custom + Built-in)
/// - Footer (Esc-to-back keyboard hint)
/// - The "child renders chromeless" pattern (caller injects tab content via
///   a view-builder; the shell handles the surrounding chrome)
///
/// **Why generic over `Tab`:** each caller declares its own enum (e.g.
/// `enum ActionsTab { case custom, builtIn }`) so the shell stays
/// agnostic. The caller tells the shell which tab id triggers the `+`
/// button via `customTabId` so non-custom tabs don't show the affordance.
///
/// **Indigo discipline (DESIGN.md):** the only indigo element rendered by
/// this shell is the `+` icon. Header text is neutral; the TabBar uses a
/// neutral active pill (set in `TabBar.swift`); the footer hint is
/// neutral. Reserve `caiPrimary` for outcome-producing affordances inside
/// the tab content.
struct ManagementScreen<Tab: Hashable, Content: View>: View {
    /// SF Symbol name for the header product mark, e.g. `bolt.circle.fill`.
    let icon: String
    /// Header title — short noun, e.g. "Actions" / "Destinations".
    let title: String
    /// Header subtitle — caller computes per-tab so it stays accurate as
    /// the user switches tabs (e.g. "12 custom actions" vs "8 of 11 visible").
    let subtitle: String
    /// TabBar specs in display order. Convention: Custom first, Built-in
    /// second (most-edited tab gets the dominant slot).
    let tabs: [TabBar<Tab>.TabSpec<Tab>]
    @Binding var selection: Tab
    /// Which tab id renders the `+` button in the header. The `+` is
    /// hidden on every other tab. Use `nil` to suppress the `+` entirely.
    let customTabId: Tab?
    /// Fired when the user taps the `+`. Caller is responsible for
    /// resetting any in-progress form state and entering "adding" mode in
    /// the embedded child view.
    let onAdd: (() -> Void)?
    /// Tab content. Caller switches on `selection` and returns the right
    /// view. The child should render WITHOUT its own header / footer —
    /// the shell provides those.
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.caiDivider)

            // Single-list screens (Secrets) pass no tabs: a one-pill TabBar is
            // noise, so the content sits directly under the header.
            if !tabs.isEmpty {
                TabBar(selection: $selection, tabs: tabs)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            content()

            Spacer(minLength: 0)
            Divider().background(Color.caiDivider)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiPrimary)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.caiTextPrimary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
            }

            Spacer()

            // `+` only on the configured custom tab. Always visible there
            // (even while editing) so the user can interrupt and start a
            // fresh add — caller's `onAdd` is responsible for cancelling
            // any in-progress form first. Tab-less screens have no gate:
            // `onAdd` alone shows it.
            if let onAdd, tabs.isEmpty || (customTabId != nil && selection == customTabId) {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.caiPrimary)
                }
                .buttonStyle(.plain)
                .help("Add new")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyboardHint(key: "Esc", label: "Back")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Standard empty-state layout used by management screens when a tab has
/// zero items. Centers the content, gives the user one clear next step.
///
/// Anatomy (DESIGN.md "Empty states"):
/// - Icon — SF Symbol, 28pt, `caiTextSecondary` at 0.4 opacity
/// - Title — 13pt medium, `caiTextPrimary`
/// - Description — 11pt, `caiTextSecondary` at 0.7 opacity, centered
/// - Optional CTA — neutral button styled to match `ChipButton`
struct ManagementEmptyState: View {
    let icon: String
    let title: String
    let description: String
    /// Optional call-to-action. Tapping it usually opens the community
    /// extensions browser ("Browse Community Extensions").
    var ctaLabel: String? = nil
    var ctaIcon: String? = nil
    var ctaAction: (() -> Void)? = nil
    /// Optional second CTA, same neutral vocabulary. Deliberately rare: the
    /// Secrets empty state is the one screen where two next steps (add,
    /// import) genuinely compete for the first click.
    var secondaryCtaLabel: String? = nil
    var secondaryCtaIcon: String? = nil
    var secondaryCtaAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.caiTextSecondary.opacity(0.4))

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }

            if ctaAction != nil || secondaryCtaAction != nil {
                HStack(spacing: 8) {
                    if let ctaLabel, let ctaAction {
                        ctaButton(label: ctaLabel, icon: ctaIcon, action: ctaAction)
                    }
                    if let secondaryCtaLabel, let secondaryCtaAction {
                        ctaButton(label: secondaryCtaLabel, icon: secondaryCtaIcon, action: secondaryCtaAction)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.vertical, 24)
    }

    private func ctaButton(label: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.caiTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.caiSurface.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
