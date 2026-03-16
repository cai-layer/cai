import SwiftUI

/// NSVisualEffectView wrapper for SwiftUI — provides the translucent blur
/// background similar to Raycast, Spotlight, and other system HUD windows.
/// Masks the view with rounded corners so it matches the outer clipShape.
///
/// Appearance-adaptive: uses `.hudWindow` for light mode (frosted glass)
/// and `.underWindowBackground` for dark mode (properly dark).
struct VisualEffectBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 20
    @Environment(\.colorScheme) var colorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = colorScheme == .dark ? .underWindowBackground : .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
        nsView.material = colorScheme == .dark ? .underWindowBackground : .hudWindow
    }
}
