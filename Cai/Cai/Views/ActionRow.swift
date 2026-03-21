import SwiftUI

struct ActionRow: View {
    let action: ActionItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.caiPrimary.opacity(0.15) : Color.caiSurface.opacity(0.6))
                    .frame(width: 28, height: 28)

                actionIcon(name: action.icon, isSelected: isSelected)
            }

            // Title + subtitle
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)

                if let subtitle = action.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Keyboard shortcut badge
            if action.shortcut <= 9 {
                HStack(spacing: 2) {
                    Text("\u{2318}")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(action.shortcut)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.caiSurface.opacity(0.5))
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.caiSelection : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(action.title)\(action.subtitle.map { ", \($0)" } ?? ""), Command \(action.shortcut)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func actionIcon(name: String, isSelected: Bool) -> some View {
        let color: Color = isSelected ? .caiPrimary : .caiTextSecondary
        switch name {
        case "github.logo":
            GitHubIcon(color: color)
                .frame(width: 14, height: 14)
        case "linear.logo":
            LinearIcon(color: color)
                .frame(width: 14, height: 14)
        default:
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(color)
        }
    }
}
