import AppKit
import SwiftUI

extension Color {
    static let caiBackground = Color(nsColor: .windowBackgroundColor).opacity(0.95)
    static let caiSurface = Color(nsColor: .controlBackgroundColor)

    // MARK: - Indigo
    //
    // Two tokens, because one hex cannot serve both jobs in dark mode.
    // `caiPrimary` is indigo as a glyph, text, border, tint or wash: it gets
    // brighter in dark (#6366F2 there is 3.8:1 on dark glass, under the 4.5:1
    // text minimum). `caiPrimaryFill` is the solid fill under white text
    // (primary buttons): it stays #6366F2 in both modes, because white on the
    // brighter dark indigo drops to 2.8:1.
    static let caiPrimary = Color(nsColor: NSColor(name: "caiPrimary") { indigo(for: $0) })
    static let caiPrimaryFill = Color(red: 0.39, green: 0.40, blue: 0.95)  // #6366F2, both modes
    /// Selection wash: 12% in light, 20% in dark, where a 12% wash on dark
    /// glass is too faint to find the selected row.
    static let caiPrimarySubtle = Color(nsColor: NSColor(name: "caiPrimarySubtle") { appearance in
        indigo(for: appearance).withAlphaComponent(isDark(appearance) ? 0.20 : 0.12)
    })

    // System colours, so dark mode and Increase Contrast get Apple's variants.
    static let caiSuccess = Color(nsColor: .systemGreen)
    static let caiError = Color(nsColor: .systemOrange)
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

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func indigo(for appearance: NSAppearance) -> NSColor {
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: return NSColor(srgbRed: 0.549, green: 0.561, blue: 0.980, alpha: 1)  // #8C8FFA
        case .accessibilityHighContrastDarkAqua: return NSColor(srgbRed: 0.655, green: 0.667, blue: 1.0, alpha: 1)  // #A7AAFF
        case .accessibilityHighContrastAqua: return NSColor(srgbRed: 0.310, green: 0.275, blue: 0.898, alpha: 1)  // #4F46E5
        default: return NSColor(srgbRed: 0.388, green: 0.400, blue: 0.949, alpha: 1)  // #6366F2, indigo-500
        }
    }
}
