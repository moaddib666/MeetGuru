import SwiftUI

/// Claude-Island's notch turned on its side: the island hangs off the right screen edge,
/// with concave shoulders above and below melting into that edge and rounded corners on
/// the open, left side. Both radii animate, which gives the liquid morph.
struct SideIslandShape: Shape {
    var shoulder: CGFloat
    var radius: CGFloat
    /// The open variant skips the screen-edge side (used for the hairline).
    var closed = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set {
            shoulder = newValue.first
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 3, rect.height / 4))
        let r = max(0, min(radius, (rect.height - 2 * s) / 2, rect.width - s))
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.minY + s), control: CGPoint(x: rect.maxX, y: rect.minY + s))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + s + r), control: CGPoint(x: rect.minX, y: rect.minY + s))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - s - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY - s), control: CGPoint(x: rect.minX, y: rect.maxY - s))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY - s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY - s))
        if closed { path.closeSubpath() }
        return path
    }
}
