import SwiftUI

/// The Cai logo rendered as a SwiftUI Shape from the SVG paths.
/// Scales to fit any frame while preserving aspect ratio.
/// Source: `_docs/planning/active/menubar-focus/logo-final.svg` (viewBox 215.85 x 127),
/// the 2026-10-31 redraw with the ⌥ at the C's stroke weight.
struct CaiLogo: View {
    var color: Color = .caiTextSecondary

    var body: some View {
        CaiLogoShape()
            .fill(color)
            .aspectRatio(CaiLogoShape.aspectRatio, contentMode: .fit)
    }
}

/// Shape that draws the Cai logo paths, normalized to a unit coordinate system.
struct CaiLogoShape: Shape {
    static let viewBox = CGSize(width: 215.85, height: 127)
    /// Width over height. Every caller that sizes the logo by hand uses this,
    /// so a redraw of the mark never leaves a stretched copy behind.
    static let aspectRatio = viewBox.width / viewBox.height

    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / Self.viewBox.width
        let scaleY = rect.height / Self.viewBox.height

        var path = Path()
        let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            .translatedBy(x: rect.minX / scaleX, y: rect.minY / scaleY)

        path.addPath(cPath().applying(transform))
        path.addPath(optionPath().applying(transform))

        return path
    }

    /// The "C" letterform
    private func cPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 185.605, y: 81.982))
        p.addLine(to: CGPoint(x: 215.619, y: 81.982))
        p.addCurve(to: CGPoint(x: 208.444, y: 106.193),
                   control1: CGPoint(x: 215.081, y: 91.985),
                   control2: CGPoint(x: 212.68, y: 99.672))
        p.addCurve(to: CGPoint(x: 190.88, y: 121.546),
                   control1: CGPoint(x: 204.262, y: 112.664),
                   control2: CGPoint(x: 198.304, y: 117.868))
        p.addCurve(to: CGPoint(x: 164.384, y: 127),
                   control1: CGPoint(x: 183.459, y: 125.165),
                   control2: CGPoint(x: 174.516, y: 127))
        p.addCurve(to: CGPoint(x: 142.389, y: 122.82),
                   control1: CGPoint(x: 156.27, y: 127),
                   control2: CGPoint(x: 148.839, y: 125.59))
        p.addCurve(to: CGPoint(x: 125.799, y: 110.831),
                   control1: CGPoint(x: 135.939, y: 120.049),
                   control2: CGPoint(x: 130.32, y: 115.99))
        p.addCurve(to: CGPoint(x: 115.475, y: 92.007),
                   control1: CGPoint(x: 121.344, y: 105.625),
                   control2: CGPoint(x: 117.861, y: 99.27))
        p.addCurve(to: CGPoint(x: 111.973, y: 67.271),
                   control1: CGPoint(x: 113.149, y: 84.7),
                   control2: CGPoint(x: 111.973, y: 76.382))
        p.addLine(to: CGPoint(x: 111.973, y: 59.895))
        p.addCurve(to: CGPoint(x: 115.646, y: 35.146),
                   control1: CGPoint(x: 111.973, y: 50.779),
                   control2: CGPoint(x: 113.207, y: 42.451))
        p.addCurve(to: CGPoint(x: 126.224, y: 16.245),
                   control1: CGPoint(x: 118.088, y: 27.831),
                   control2: CGPoint(x: 121.66, y: 21.444))
        p.addCurve(to: CGPoint(x: 142.804, y: 4.182),
                   control1: CGPoint(x: 130.793, y: 11.039),
                   control2: CGPoint(x: 136.409, y: 6.953))
        p.addCurve(to: CGPoint(x: 164.3, y: 0),
                   control1: CGPoint(x: 149.196, y: 1.411),
                   control2: CGPoint(x: 156.462, y: 0))
        p.addCurve(to: CGPoint(x: 191.242, y: 5.717),
                   control1: CGPoint(x: 174.827, y: 0),
                   control2: CGPoint(x: 183.927, y: 1.924))
        p.addCurve(to: CGPoint(x: 208.382, y: 21.505),
                   control1: CGPoint(x: 198.555, y: 9.509),
                   control2: CGPoint(x: 204.372, y: 14.865))
        p.addCurve(to: CGPoint(x: 215.85, y: 45.847),
                   control1: CGPoint(x: 212.431, y: 28.115),
                   control2: CGPoint(x: 214.903, y: 35.81))
        p.addLine(to: CGPoint(x: 185.672, y: 45.847))
        p.addCurve(to: CGPoint(x: 183.071, y: 33.172),
                   control1: CGPoint(x: 185.389, y: 39.892),
                   control2: CGPoint(x: 184.561, y: 36.229))
        p.addCurve(to: CGPoint(x: 176.522, y: 26.456),
                   control1: CGPoint(x: 181.611, y: 30.123),
                   control2: CGPoint(x: 179.545, y: 28.005))
        p.addCurve(to: CGPoint(x: 164.3, y: 24.129),
                   control1: CGPoint(x: 173.471, y: 24.892),
                   control2: CGPoint(x: 169.516, y: 24.129))
        p.addCurve(to: CGPoint(x: 154.649, y: 26.135),
                   control1: CGPoint(x: 160.546, y: 24.129),
                   control2: CGPoint(x: 157.438, y: 24.78))
        p.addCurve(to: CGPoint(x: 147.957, y: 32.322),
                   control1: CGPoint(x: 151.94, y: 27.477),
                   control2: CGPoint(x: 149.804, y: 29.448))
        p.addCurve(to: CGPoint(x: 143.887, y: 43.439),
                   control1: CGPoint(x: 146.145, y: 35.226),
                   control2: CGPoint(x: 144.814, y: 38.849))
        p.addCurve(to: CGPoint(x: 142.493, y: 59.729),
                   control1: CGPoint(x: 142.955, y: 48),
                   control2: CGPoint(x: 142.493, y: 53.38))
        p.addLine(to: CGPoint(x: 142.493, y: 67.271))
        p.addCurve(to: CGPoint(x: 143.725, y: 83.51),
                   control1: CGPoint(x: 142.493, y: 73.572),
                   control2: CGPoint(x: 142.902, y: 78.941))
        p.addCurve(to: CGPoint(x: 147.55, y: 94.528),
                   control1: CGPoint(x: 144.542, y: 88.039),
                   control2: CGPoint(x: 145.793, y: 91.628))
        p.addCurve(to: CGPoint(x: 154.245, y: 100.788),
                   control1: CGPoint(x: 149.339, y: 97.397),
                   control2: CGPoint(x: 151.474, y: 99.39))
        p.addCurve(to: CGPoint(x: 164.384, y: 102.871),
                   control1: CGPoint(x: 157.03, y: 102.194),
                   control2: CGPoint(x: 160.293, y: 102.871))
        p.addCurve(to: CGPoint(x: 175.898, y: 100.77),
                   control1: CGPoint(x: 169.104, y: 102.871),
                   control2: CGPoint(x: 172.837, y: 102.182))
        p.addCurve(to: CGPoint(x: 182.693, y: 94.415),
                   control1: CGPoint(x: 178.922, y: 99.324),
                   control2: CGPoint(x: 181.075, y: 97.311))
        p.addCurve(to: CGPoint(x: 185.605, y: 81.982),
                   control1: CGPoint(x: 184.331, y: 91.484),
                   control2: CGPoint(x: 185.253, y: 87.907))
        p.closeSubpath()
        return p
    }

    /// The "⌥" glyph: the slanted stroke and the short top-right bar
    private func optionPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 66.824, y: 111.004))
        p.addLine(to: CGPoint(x: 28.264, y: 46.143))
        p.addLine(to: CGPoint(x: 0, y: 46.143))
        p.addLine(to: CGPoint(x: 0, y: 24.721))
        p.addLine(to: CGPoint(x: 35.94, y: 24.721))
        p.addLine(to: CGPoint(x: 74.499, y: 89.583))
        p.addLine(to: CGPoint(x: 102.763, y: 89.583))
        p.addLine(to: CGPoint(x: 102.763, y: 111.004))
        p.addLine(to: CGPoint(x: 66.824, y: 111.004))
        p.closeSubpath()
        p.move(to: CGPoint(x: 65.152, y: 46.143))
        p.addLine(to: CGPoint(x: 65.152, y: 24.721))
        p.addLine(to: CGPoint(x: 102.763, y: 24.721))
        p.addLine(to: CGPoint(x: 102.763, y: 46.143))
        p.addLine(to: CGPoint(x: 65.152, y: 46.143))
        p.closeSubpath()
        return p
    }
}
