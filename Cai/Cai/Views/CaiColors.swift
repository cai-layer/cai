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
}
