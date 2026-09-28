import Foundation

/// A user-placed alignment line. Horizontal guides sit at a document Y; vertical at a document X.
nonisolated struct CanvasGuide: Codable, Equatable, Sendable, Hashable {
    enum Axis: String, Codable, Sendable { case horizontal, vertical }
    var id: UUID
    var axis: Axis
    /// Document pixels: Y for a horizontal guide, X for a vertical one.
    var position: Double

    func offset(x: CGFloat, y: CGFloat) -> CanvasGuide {
        var guide = self
        guide.position += Double(axis == .vertical ? x : y)
        return guide
    }

    func scaled(x: CGFloat, y: CGFloat) -> CanvasGuide {
        var guide = self
        guide.position *= Double(axis == .vertical ? x : y)
        return guide
    }

    /// Mirrors this guide when it runs perpendicular to the flip, so it stays on the same content.
    func mirrored(horizontally: Bool, across center: CGFloat) -> CanvasGuide {
        var guide = self
        if (horizontally && axis == .vertical) || (!horizontally && axis == .horizontal) {
            guide.position = Double(2 * center) - guide.position
        }
        return guide
    }
}
