import SwiftUI

/// Reusable keyboard shortcut hint shown in view footers (e.g. "↵ Copy", "Esc Back").
struct KeyboardHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.caiSurface.opacity(0.5))
                )
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.caiTextSecondary.opacity(0.6))
    }
}
