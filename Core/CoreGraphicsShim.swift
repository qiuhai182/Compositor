// The geometry vocabulary Core speaks, for the platforms without Core Graphics.
// On Apple platforms the real Core Graphics is used and this file compiles to nothing.
// CGFloat comes from Foundation on every platform, so it is not defined here.

#if !canImport(CoreGraphics)

// Codable, because the .comp manifest's types (LayerTransform and friends) are and must encode
// with the same x/y, width/height keys Apple's own CG types use.

public struct CGPoint: Equatable, Codable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public init() { self.x = 0; self.y = 0 }
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
}

public struct CGSize: Equatable, Codable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public init() { self.width = 0; self.height = 0 }
    public init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }
}

public struct CGRect: Equatable, Sendable {
    public var origin: CGPoint
    public var size: CGSize
    public init() { self.origin = CGPoint(); self.size = CGSize() }
    public init(origin: CGPoint, size: CGSize) { self.origin = origin; self.size = size }
    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }
    public static let null = CGRect(x: .infinity, y: .infinity, width: 0, height: 0)
    public var isNull: Bool { self == CGRect.null }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var minX: CGFloat { origin.x }
    public var minY: CGFloat { origin.y }
    public var midX: CGFloat { origin.x + size.width / 2 }
    public var midY: CGFloat { origin.y + size.height / 2 }
    public var maxX: CGFloat { origin.x + size.width }
    public var maxY: CGFloat { origin.y + size.height }
    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
    public func contains(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
    public func intersection(_ other: CGRect) -> CGRect {
        let x0 = max(minX, other.minX), x1 = min(maxX, other.maxX)
        let y0 = max(minY, other.minY), y1 = min(maxY, other.maxY)
        return x1 > x0 && y1 > y0 ? CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .null
    }
}

public enum CGInterpolationQuality: Sendable {
    case none, low, medium, high, `default`
}

#endif
