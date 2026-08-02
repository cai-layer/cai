import SwiftUI

extension Color {
    static let caiBackground = Color(nsColor: .windowBackgroundColor).opacity(0.95)
    static let caiSurface = Color(nsColor: .controlBackgroundColor)
    static let caiPrimary = Color(red: 0.39, green: 0.40, blue: 0.95)  // #6366F2 — indigo-500
    static let caiPrimarySubtle = Color(red: 0.39, green: 0.40, blue: 0.95).opacity(0.12)  // hover/selection wash
    static let caiSuccess = Color(red: 0.204, green: 0.780, blue: 0.349)  // #34C759 — Apple system green
    static let caiError = Color(red: 1.0, green: 0.584, blue: 0.0)  // #FF9500 — Apple system orange
    static let caiTextPrimary = Color(nsColor: .labelColor)
    static let caiTextSecondary = Color(nsColor: .secondaryLabelColor)
    static let caiSelection = Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
    static let caiDivider = Color(nsColor: .separatorColor)

    // MARK: - Diff tint (the one place red appears)
    //
    // Cai has no red anywhere else: warnings are orange, and nothing in the
    // product is styled as a failure. Diffs are the deliberate exception,
    // because red-removed / green-added is a convention every developer reads
    // without thinking, and an approval sheet is the wrong place to make
    // someone learn a house dialect. Only ever used as a row tint behind a
    // line of a diff, never as text or as a control.
    static let caiDiffRemoved = Color(nsColor: .systemRed)
    static let caiDiffAdded = Color(nsColor: .systemGreen)
}
