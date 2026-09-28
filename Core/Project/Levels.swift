import Foundation

// The Levels adjustment's stored settings: per-channel black/white points, gamma and output
// range, with the pure math that normalizes and applies them. Reading pixels stays in the app.

nonisolated enum LevelsChannel: String, CaseIterable, Sendable, Codable {
    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    var index: Int { Self.allCases.firstIndex(of: self)! }
}
nonisolated struct LevelRange: Equatable, Sendable, Codable {
    var black: Double = 0
    var gamma: Double = 1
    var white: Double = 255
    var outputBlack: Double = 0
    var outputWhite: Double = 255
    var normalized: Self {
        func clamp(_ n: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            n.isFinite ? min(range.upperBound, max(range.lowerBound, n)) : fallback
        }
        var result = self
        result.black = clamp(black, 0...254, 0)
        result.white = clamp(white, (result.black + 1)...255, 255)
        result.gamma = clamp(gamma, 0.1...9.99, 1)
        result.outputBlack = clamp(outputBlack, 0...255, 0)
        result.outputWhite = clamp(outputWhite, 0...255, 255)
        return result
    }
    func apply(_ value: Double) -> Double {
        let s = normalized
        let input = min(1, max(0, (value * 255 - s.black) / (s.white - s.black)))
        return (s.outputBlack + pow(input, 1 / s.gamma) * (s.outputWhite - s.outputBlack)) / 255
    }
}
nonisolated struct LevelsSettings: Equatable, Sendable, Codable {
    var channel: LevelsChannel = .rgb
    var ranges = Array(repeating: LevelRange(), count: 4)
    var current: LevelRange {
        get { ranges[channel.index] }
        set { ranges[channel.index] = newValue.normalized }
    }
    var isIdentity: Bool { ranges.allSatisfy { $0.normalized == LevelRange() } }
    /// Individual channels, followed by the composite RGB adjustment.
    func apply(_ value: Double, channel: LevelsChannel) -> Double {
        ranges[0].apply(ranges[channel.index].apply(value))
    }
}
