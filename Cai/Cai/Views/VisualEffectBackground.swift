import SwiftUI

/// NSVisualEffectView wrapper for SwiftUI — provides the translucent blur
/// background similar to Raycast, Spotlight, and other system HUD windows.
/// Masks the view with rounded corners so it matches the outer clipShape.
///
/// When `reduceTransparency` is true, uses a solid window background instead
/// of the translucent blur effect.
struct VisualEffectBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 20
    var reduceTransparency: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configureView(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configureView(nsView)
    }

    private func configureView(_ view: NSVisualEffectView) {
        if reduceTransparency {
            view.material = .windowBackground
            view.blendingMode = .withinWindow
            view.state = .inactive
        } else {
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
        }
        view.isEmphasized = !reduceTransparency
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}
