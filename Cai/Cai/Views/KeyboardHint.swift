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

/// Submit-key hint for the Ask AI prompt composers — the initial Ask AI box
/// (CustomPromptView) and the follow-up input on a result (ResultView). Shared
/// so the two footers stay in sync, and reflects the "Return to submit" setting:
/// ON shows "↵ to send", OFF shows "⌘↵ to send". The Shift+Return-for-newline
/// behavior is taught at the toggle in Settings, so it's omitted here.
struct PromptSubmitHint: View {
    let pressReturnToSend: Bool

    var body: some View {
        KeyboardHint(key: pressReturnToSend ? "↵" : "⌘↵", label: "to send")
    }
}
