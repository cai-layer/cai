import SwiftUI

/// The Cai logo rendered as a SwiftUI Shape from the SVG paths.
/// Scales to fit any frame while preserving aspect ratio.
/// Source: `_docs/planning/active/menubar-focus/logo-final.svg` (viewBox 212.708 x 127),
/// derived from the app icon so the two never drift; the ⌥ at the C's stroke weight.
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
    static let viewBox = CGSize(width: 212.708, height: 127)
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
        p.move(to: CGPoint(x: 185.202, y: 83.903))
        p.addLine(to: CGPoint(x: 212.539, y: 83.903))
        p.addCurve(to: CGPoint(x: 205.62, y: 106.385),
                   control1: CGPoint(x: 212.089, y: 92.387),
                   control2: CGPoint(x: 209.783, y: 99.881))
        p.addCurve(to: CGPoint(x: 188.493, y: 121.571),
                   control1: CGPoint(x: 201.514, y: 112.832),
                   control2: CGPoint(x: 195.805, y: 117.894))
        p.addCurve(to: CGPoint(x: 162.421, y: 127),
                   control1: CGPoint(x: 181.18, y: 125.19),
                   control2: CGPoint(x: 172.49, y: 127))
        p.addCurve(to: CGPoint(x: 140.822, y: 122.843),
                   control1: CGPoint(x: 154.378, y: 127),
                   control2: CGPoint(x: 147.178, y: 125.614))
        p.addCurve(to: CGPoint(x: 124.622, y: 110.966),
                   control1: CGPoint(x: 134.466, y: 120.072),
                   control2: CGPoint(x: 129.066, y: 116.113))
        p.addCurve(to: CGPoint(x: 114.497, y: 92.217),
                   control1: CGPoint(x: 120.235, y: 105.763),
                   control2: CGPoint(x: 116.86, y: 99.513))
        p.addCurve(to: CGPoint(x: 111.038, y: 67.36),
                   control1: CGPoint(x: 112.191, y: 84.864),
                   control2: CGPoint(x: 111.038, y: 76.579))
        p.addLine(to: CGPoint(x: 111.038, y: 59.81))
        p.addCurve(to: CGPoint(x: 114.666, y: 34.952),
                   control1: CGPoint(x: 111.038, y: 50.591),
                   control2: CGPoint(x: 112.248, y: 42.305))
        p.addCurve(to: CGPoint(x: 125.044, y: 16.119),
                   control1: CGPoint(x: 117.085, y: 27.6),
                   control2: CGPoint(x: 120.544, y: 21.322))
        p.addCurve(to: CGPoint(x: 141.244, y: 4.157),
                   control1: CGPoint(x: 129.544, y: 10.916),
                   control2: CGPoint(x: 134.944, y: 6.928))
        p.addCurve(to: CGPoint(x: 162.337, y: 0),
                   control1: CGPoint(x: 147.543, y: 1.386),
                   control2: CGPoint(x: 154.575, y: 0))
        p.addCurve(to: CGPoint(x: 188.83, y: 5.684),
                   control1: CGPoint(x: 172.799, y: 0),
                   control2: CGPoint(x: 181.63, y: 1.895))
        p.addCurve(to: CGPoint(x: 205.536, y: 21.294),
                   control1: CGPoint(x: 196.03, y: 9.473),
                   control2: CGPoint(x: 201.599, y: 14.677))
        p.addCurve(to: CGPoint(x: 212.708, y: 43.945),
                   control1: CGPoint(x: 209.53, y: 27.911),
                   control2: CGPoint(x: 211.92, y: 35.461))
        p.addLine(to: CGPoint(x: 185.286, y: 43.945))
        p.addCurve(to: CGPoint(x: 182.586, y: 31.813),
                   control1: CGPoint(x: 185.062, y: 39.138),
                   control2: CGPoint(x: 184.161, y: 35.094))
        p.addCurve(to: CGPoint(x: 175.33, y: 24.263),
                   control1: CGPoint(x: 181.011, y: 28.477),
                   control2: CGPoint(x: 178.593, y: 25.96))
        p.addCurve(to: CGPoint(x: 162.337, y: 21.718),
                   control1: CGPoint(x: 172.068, y: 22.566),
                   control2: CGPoint(x: 167.737, y: 21.718))
        p.addCurve(to: CGPoint(x: 151.959, y: 23.924),
                   control1: CGPoint(x: 158.4, y: 21.718),
                   control2: CGPoint(x: 154.94, y: 22.453))
        p.addCurve(to: CGPoint(x: 144.619, y: 30.796),
                   control1: CGPoint(x: 149.034, y: 25.394),
                   control2: CGPoint(x: 146.587, y: 27.685))
        p.addCurve(to: CGPoint(x: 140.316, y: 42.673),
                   control1: CGPoint(x: 142.706, y: 33.906),
                   control2: CGPoint(x: 141.272, y: 37.865))
        p.addCurve(to: CGPoint(x: 138.881, y: 59.64),
                   control1: CGPoint(x: 139.36, y: 47.423),
                   control2: CGPoint(x: 138.881, y: 53.079))
        p.addLine(to: CGPoint(x: 138.881, y: 67.36))
        p.addCurve(to: CGPoint(x: 140.147, y: 84.243),
                   control1: CGPoint(x: 138.881, y: 73.864),
                   control2: CGPoint(x: 139.303, y: 79.492))
        p.addCurve(to: CGPoint(x: 144.197, y: 96.035),
                   control1: CGPoint(x: 140.99, y: 88.993),
                   control2: CGPoint(x: 142.341, y: 92.924))
        p.addCurve(to: CGPoint(x: 151.537, y: 102.991),
                   control1: CGPoint(x: 146.109, y: 99.145),
                   control2: CGPoint(x: 148.556, y: 101.464))
        p.addCurve(to: CGPoint(x: 162.421, y: 105.282),
                   control1: CGPoint(x: 154.518, y: 104.518),
                   control2: CGPoint(x: 158.147, y: 105.282))
        p.addCurve(to: CGPoint(x: 174.656, y: 102.991),
                   control1: CGPoint(x: 167.315, y: 105.282),
                   control2: CGPoint(x: 171.393, y: 104.518))
        p.addCurve(to: CGPoint(x: 182.164, y: 95.865),
                   control1: CGPoint(x: 177.918, y: 101.408),
                   control2: CGPoint(x: 180.421, y: 99.032))
        p.addCurve(to: CGPoint(x: 185.202, y: 83.903),
                   control1: CGPoint(x: 183.908, y: 92.698),
                   control2: CGPoint(x: 184.921, y: 88.711))
        p.closeSubpath()
        return p
    }

    /// The "⌥" glyph: the slanted stroke and the short top-right bar
    private func optionPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 64.794, y: 109.997))
        p.addLine(to: CGPoint(x: 27.474, y: 44.077))
        p.addLine(to: CGPoint(x: 0, y: 44.077))
        p.addLine(to: CGPoint(x: 0, y: 21.861))
        p.addLine(to: CGPoint(x: 35.488, y: 21.861))
        p.addLine(to: CGPoint(x: 72.807, y: 87.781))
        p.addLine(to: CGPoint(x: 100.281, y: 87.781))
        p.addLine(to: CGPoint(x: 100.281, y: 109.997))
        p.closeSubpath()
        p.move(to: CGPoint(x: 63.057, y: 44.077))
        p.addLine(to: CGPoint(x: 63.057, y: 21.861))
        p.addLine(to: CGPoint(x: 100.281, y: 21.861))
        p.addLine(to: CGPoint(x: 100.281, y: 44.077))
        p.closeSubpath()
        return p
    }
}
