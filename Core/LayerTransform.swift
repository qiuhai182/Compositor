import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum LayerSampling: String, CaseIterable, Codable, Sendable {
    case nearest = "Nearest"
    case smooth = "Smooth"
    case high = "High quality"
    var quality: CGInterpolationQuality {
        switch self {
        case .nearest: return .none
        case .smooth: return .low
        case .high: return .high
        }
    }
}

/// Unrotated bounds in document pixels; rotation is clockwise around their center.
nonisolated struct LayerTransform: Equatable, Codable, Sendable {
    var origin: CGPoint
    var size: CGSize
    var rotation: CGFloat = 0
    var flipX = false
    var flipY = false
    var sampling: LayerSampling = .high
    var center: CGPoint { CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2) }
    var radians: CGFloat { rotation.truncatingRemainder(dividingBy: 360) * .pi / 180 }
    var isValid: Bool {
        [origin.x, origin.y, size.width, size.height, rotation].allSatisfy(\.isFinite)
            && (1...300_000).contains(size.width) && (1...300_000).contains(size.height)
            && abs(origin.x) <= 1_000_000 && abs(origin.y) <= 1_000_000
    }
    func point(_ unit: CGPoint) -> CGPoint {
        let x = (unit.x - 0.5) * size.width, y = (unit.y - 0.5) * size.height
        return CGPoint(x: center.x + x * cos(radians) - y * sin(radians),
                       y: center.y + x * sin(radians) + y * cos(radians))
    }
    func contains(_ point: CGPoint) -> Bool {
        let x = point.x - center.x, y = point.y - center.y
        return abs(x * cos(radians) + y * sin(radians)) <= size.width / 2
            && abs(-x * sin(radians) + y * cos(radians)) <= size.height / 2
    }
    /// Width as a percentage of the `pixelSize` it places (100% draws them 1:1).
    func scalePercent(pixelSize: CGSize) -> CGFloat { size.width / max(1, pixelSize.width) * 100 }
    /// Both sides set to `percent` of `pixelSize`, keeping the center (and rotation and flips).
    func scaled(toPercent percent: CGFloat, pixelSize: CGSize) -> LayerTransform {
        var result = self
        result.size = CGSize(width: pixelSize.width * percent / 100, height: pixelSize.height * percent / 100)
        result.origin = CGPoint(x: center.x - result.size.width / 2, y: center.y - result.size.height / 2)
        return result
    }
    /// Whole pixels and whole degrees: what dragging, scaling and rotating leave behind. Typed values are used
    /// as they are, so a fraction can still be asked for by hand.
    func rounded() -> LayerTransform {
        var result = self
        result.origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        result.size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        result.rotation = rotation.rounded()
        return result
    }
    /// The same place on the document, whatever the sampling.
    func samePlacement(as other: LayerTransform) -> Bool {
        var copy = self
        copy.sampling = other.sampling
        return copy == other
    }
    static let handles = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0),
                          CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 1),
                          CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0.5)]
}
