import SwiftUI

/// Linear logo rendered as a SwiftUI Shape.
/// Path data from the official Linear SVG asset (assets/logo-dark.svg).
/// Original viewBox: 100 x 100
struct LinearIcon: View {
    var color: Color = .caiTextSecondary

    var body: some View {
        LinearIconShape()
            .fill(color)
            .aspectRatio(1.0, contentMode: .fit)
    }
}

struct LinearIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 100.0
        let scaleY = rect.height / 100.0
        let t = CGAffineTransform(scaleX: scaleX, y: scaleY)

        var p = Path()

        // Bottom-left swoosh
        p.move(to: CGPoint(x: 1.22541, y: 61.5228))
        p.addCurve(to: CGPoint(x: 2.82179, y: 60.6658),
                    control1: CGPoint(x: 1.00291, y: 60.5743),
                    control2: CGPoint(x: 2.13289, y: 59.9769))
        p.addLine(to: CGPoint(x: 39.3342, y: 97.1782))
        p.addCurve(to: CGPoint(x: 38.4772, y: 98.7746),
                    control1: CGPoint(x: 40.0231, y: 97.8671),
                    control2: CGPoint(x: 39.4257, y: 98.9971))
        p.addCurve(to: CGPoint(x: 1.22541, y: 61.5228),
                    control1: CGPoint(x: 20.0515, y: 94.4522),
                    control2: CGPoint(x: 5.54779, y: 79.9485))
        p.closeSubpath()

        // Middle arc
        p.move(to: CGPoint(x: 0.00189135, y: 46.8891))
        p.addCurve(to: CGPoint(x: 0.291463, y: 47.6497),
                    control1: CGPoint(x: -0.015752, y: 47.1724),
                    control2: CGPoint(x: 0.090763, y: 47.449))
        p.addLine(to: CGPoint(x: 52.3503, y: 99.7085))
        p.addCurve(to: CGPoint(x: 53.1109, y: 99.9981),
                    control1: CGPoint(x: 52.551, y: 99.9092),
                    control2: CGPoint(x: 52.8276, y: 100.016))
        p.addCurve(to: CGPoint(x: 60.0733, y: 99.0722),
                    control1: CGPoint(x: 55.4801, y: 99.8505),
                    control2: CGPoint(x: 57.8047, y: 99.5381))
        p.addCurve(to: CGPoint(x: 60.5515, y: 97.4241),
                    control1: CGPoint(x: 60.8378, y: 98.9152),
                    control2: CGPoint(x: 61.1034, y: 97.9759))
        p.addLine(to: CGPoint(x: 2.57595, y: 39.4485))
        p.addCurve(to: CGPoint(x: 0.927776, y: 39.9267),
                    control1: CGPoint(x: 2.02409, y: 38.8966),
                    control2: CGPoint(x: 1.08478, y: 39.1622))
        p.addCurve(to: CGPoint(x: 0.00189135, y: 46.8891),
                    control1: CGPoint(x: 0.461861, y: 42.1953),
                    control2: CGPoint(x: 0.149456, y: 44.5199))
        p.closeSubpath()

        // Left arc
        p.move(to: CGPoint(x: 4.21093, y: 29.7054))
        p.addCurve(to: CGPoint(x: 4.41858, y: 30.8054),
                    control1: CGPoint(x: 4.04444, y: 30.0792),
                    control2: CGPoint(x: 4.12924, y: 30.516))
        p.addLine(to: CGPoint(x: 69.1946, y: 95.5814))
        p.addCurve(to: CGPoint(x: 70.2946, y: 95.7891),
                    control1: CGPoint(x: 69.484, y: 95.8708),
                    control2: CGPoint(x: 69.9208, y: 95.9556))
        p.addCurve(to: CGPoint(x: 75.4801, y: 93.1051),
                    control1: CGPoint(x: 72.0807, y: 94.9935),
                    control2: CGPoint(x: 73.8117, y: 94.0964))
        p.addCurve(to: CGPoint(x: 75.6633, y: 91.5644),
                    control1: CGPoint(x: 76.0322, y: 92.7771),
                    control2: CGPoint(x: 76.1174, y: 92.0184))
        p.addLine(to: CGPoint(x: 8.43566, y: 24.3367))
        p.addCurve(to: CGPoint(x: 6.89492, y: 24.5199),
                    control1: CGPoint(x: 7.98157, y: 23.8826),
                    control2: CGPoint(x: 7.22295, y: 23.9678))
        p.addCurve(to: CGPoint(x: 4.21093, y: 29.7054),
                    control1: CGPoint(x: 5.9036, y: 26.1883),
                    control2: CGPoint(x: 5.00649, y: 27.9193))
        p.closeSubpath()

        // Main quarter-circle
        p.move(to: CGPoint(x: 12.6587, y: 18.074))
        p.addCurve(to: CGPoint(x: 12.6144, y: 16.7199),
                    control1: CGPoint(x: 12.2886, y: 17.7039),
                    control2: CGPoint(x: 12.2657, y: 17.1103))
        p.addCurve(to: CGPoint(x: 49.9519, y: 0),
                    control1: CGPoint(x: 21.7795, y: 6.45931),
                    control2: CGPoint(x: 35.1114, y: 0))
        p.addCurve(to: CGPoint(x: 100, y: 50.0481),
                    control1: CGPoint(x: 77.5927, y: 0),
                    control2: CGPoint(x: 100, y: 22.4073))
        p.addCurve(to: CGPoint(x: 83.2801, y: 87.3856),
                    control1: CGPoint(x: 100, y: 64.8886),
                    control2: CGPoint(x: 93.5407, y: 78.2205))
        p.addCurve(to: CGPoint(x: 81.9259, y: 87.3413),
                    control1: CGPoint(x: 82.8898, y: 87.7343),
                    control2: CGPoint(x: 82.2961, y: 87.7114))
        p.addLine(to: CGPoint(x: 12.6587, y: 18.074))
        p.closeSubpath()

        return p.applying(t)
    }
}
