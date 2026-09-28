import Foundation

// The Curves adjustment's stored settings: the per-channel handle points and the pure math that
// interpolates them. Rendering the curve into pixels stays in the app.

nonisolated struct CurvePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}
nonisolated struct CurvesSettings: Codable, Equatable, Sendable {
    var channel = LevelsChannel.rgb
    var channels = Array(repeating: [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 255)], count: 4)
    var isValid: Bool {
        channels.count == 4 && channels.allSatisfy { points in
            (2...32).contains(points.count) && points.first?.x == 0 && points.last?.x == 255
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...255).contains($0.x) && (0...255).contains($0.y) }
            && zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x }
        }
    }
    /// Shape-preserving cubic Hermite interpolation avoids overshoot between handles.
    func value(_ x: Double, channel: Int) -> Double {
        let p = channels[channel]
        let i = min(p.count - 2, max(0, p.lastIndex(where: { $0.x <= x }) ?? 0))
        let d = zip(p, p.dropFirst()).map { ($1.y - $0.y) / ($1.x - $0.x) }
        func slope(_ j: Int) -> Double {
            if j == 0 { return d[0] }
            if j == p.count-1 { return d.last! }
            if d[j-1] * d[j] <= 0 { return 0 }
            return 2 / (1/d[j-1] + 1/d[j])
        }
        let h = p[i+1].x-p[i].x, t = min(1, max(0, (x-p[i].x)/h))
        let y = (2*t*t*t-3*t*t+1)*p[i].y + (t*t*t-2*t*t+t)*h*slope(i)
            + (-2*t*t*t+3*t*t)*p[i+1].y + (t*t*t-t*t)*h*slope(i+1)
        return min(255, max(0, y))
    }
}
