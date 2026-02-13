import SwiftUI

/// Small chip showing an output destination with keyboard shortcut hint.
/// Used in ResultView and CustomPromptView footers.
struct DestinationChip: View {
    let destination: OutputDestination
    let shortcut: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: destination.icon)
                    .font(.system(size: 10, weight: .medium))

                Text(destination.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)

                if shortcut >= 1 && shortcut <= 9 {
                    Text("\u{2318}\(shortcut)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(.caiTextSecondary.opacity(0.5))
                }
            }
            .foregroundColor(isSelected ? .caiPrimary : .caiTextSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? Color.caiPrimary.opacity(0.15)
                          : Color.caiSurface.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
