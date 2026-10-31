import SwiftUI

/// Reusable two-tab segmented bar with optional per-tab counts.
///
/// Used by parent management screens that group related sub-screens
/// (`ActionsManagementView` for Custom + Built-in actions;
/// `DestinationsParentView` for Built-in + Custom destinations) so the
/// user can switch context without leaving the screen.
///
/// **Visual language:** macOS-native segmented-control look — recessed
/// neutral track with a slightly raised neutral pill on the active tab.
/// No indigo on this control: under the "indigo discipline" rule
/// (DESIGN.md), tab indicators are passive structure, not outcome-
/// producing affordances. Compact (28pt height) so it fits cleanly under
/// the screen header without competing for vertical space.
///
/// Generic over a tab identifier — typically a tiny enum like
/// `enum ActionsTab { case custom, builtIn }` declared by the caller.
struct TabBar<Tab: Hashable>: View {
    @Binding var selection: Tab
    let tabs: [TabSpec<Tab>]
    @Environment(\.colorScheme) private var colorScheme

    private var activeFill: Color {
        colorScheme == .dark ? .white.opacity(0.16) : Color(nsColor: .windowBackgroundColor)
    }

    struct TabSpec<T: Hashable>: Identifiable {
        let id: T
        let label: String
        let count: Int?
        init(id: T, label: String, count: Int? = nil) {
            self.id = id
            self.label = label
            self.count = count
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.caiSurface.opacity(0.5))
        )
    }

    private func tabButton(_ tab: TabSpec<Tab>) -> some View {
        let isActive = selection == tab.id
        return Button(action: {
            withAnimation(.easeOut(duration: 0.15)) {
                selection = tab.id
            }
        }) {
            HStack(spacing: 5) {
                Text(tab.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isActive ? .caiTextPrimary : .caiTextSecondary)
                if let count = tab.count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.caiTextSecondary.opacity(isActive ? 0.8 : 0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    // In dark, windowBackgroundColor is nearly the glass behind
                    // it, so the active segment is a white wash there instead.
                    .fill(isActive ? activeFill : Color.clear)
                    .shadow(
                        color: isActive ? Color.black.opacity(colorScheme == .dark ? 0.3 : 0.04) : .clear,
                        radius: 0.5,
                        x: 0,
                        y: 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
