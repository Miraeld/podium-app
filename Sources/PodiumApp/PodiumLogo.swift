#if os(macOS)
import SwiftUI

// MARK: - Podium brand "eye" logo
//
// Recreated as pure SwiftUI from the official WP Media brand mark. All geometry
// is authored in a 100×100 design space and scaled to `size`, so it renders
// crisply at any size. The gold gradient (#FFE27A → #FED23A → #C9A227) matches
// Theme.accentGradient; the tile is a deep navy radial gradient.

struct PodiumLogo: View {
    var size: CGFloat = 28

    // Gold gradient (topLeading → bottomTrailing), matches the brand.
    private let gold = LinearGradient(
        colors: [
            Color(red: 1, green: 0.886, blue: 0.478),    // #FFE27A
            Color(red: 254/255, green: 210/255, blue: 58/255), // #FED23A
            Color(red: 0.788, green: 0.635, blue: 0.153) // #C9A227
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            // Rounded-square tile, radial navy gradient.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 20/255, green: 21/255, blue: 32/255), // #141520
                            Color(red: 10/255, green: 11/255, blue: 18/255)  // #0A0B12
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 60
                    )
                )
                .frame(width: 100, height: 100)

            // Concentric gold rings.
            Circle()
                .stroke(gold.opacity(0.55), lineWidth: 1.1)
                .frame(width: 39, height: 39)   // r = 19.5
            Circle()
                .stroke(gold.opacity(0.35), lineWidth: 1.0)
                .frame(width: 54.6, height: 54.6) // r = 27.3
            Circle()
                .stroke(gold.opacity(0.20), lineWidth: 0.9)
                .frame(width: 72.2, height: 72.2) // r = 36.1

            // Eye-lens outline.
            EyeLensShape()
                .stroke(gold, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 100, height: 100)

            // Iris.
            Circle()
                .fill(Color(red: 10/255, green: 11/255, blue: 18/255)) // #0A0B12
                .frame(width: 28.2, height: 28.2) // r = 14.1

            // White ring.
            Circle()
                .stroke(Color.white, lineWidth: 1.6)
                .frame(width: 21.4, height: 21.4) // r = 10.7

            // Gold pupil.
            Circle()
                .fill(gold)
                .frame(width: 8.6, height: 8.6) // r = 4.3
        }
        .frame(width: 100, height: 100)
        .scaleEffect(size / 100)
        .frame(width: size, height: size)
    }
}

// The eye-lens almond path, authored in the 100×100 space.
private struct EyeLensShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Scale the 100-space coordinates to the actual rect.
        let sx = rect.width / 100
        let sy = rect.height / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        path.move(to: p(19.5, 50))
        path.addCurve(to: p(80.5, 50), control1: p(32.2, 32.2), control2: p(67.8, 32.2))
        path.addCurve(to: p(19.5, 50), control1: p(67.8, 67.8), control2: p(32.2, 67.8))
        path.closeSubpath()
        return path
    }
}

#endif
