import Foundation

// The Hue/Saturation adjustment's vocabulary: the color ranges, the per-range hue bands, and the
// settings the manifest stores. Building and applying the color cube stays in the app.

/// The six color ranges plus Master, as in Photoshop's Cmd+U.
nonisolated enum ColorRange: String, CaseIterable, Sendable, Hashable, Codable {
    case master = "Master", reds = "Reds", yellows = "Yellows", greens = "Greens"
    case cyans = "Cyans", blues = "Blues", magentas = "Magentas"

    /// Photoshop's starting hue band: falloff start, range start, range end, falloff end.
    var defaultBand: HueBand {
        switch self {
        case .master: HueBand(falloffStart: 0, rangeStart: 0, rangeEnd: 360, falloffEnd: 360)
        case .reds: HueBand(falloffStart: 315, rangeStart: 345, rangeEnd: 15, falloffEnd: 45)
        case .yellows: HueBand(falloffStart: 15, rangeStart: 45, rangeEnd: 75, falloffEnd: 105)
        case .greens: HueBand(falloffStart: 75, rangeStart: 105, rangeEnd: 135, falloffEnd: 165)
        case .cyans: HueBand(falloffStart: 135, rangeStart: 165, rangeEnd: 195, falloffEnd: 225)
        case .blues: HueBand(falloffStart: 195, rangeStart: 225, rangeEnd: 255, falloffEnd: 285)
        case .magentas: HueBand(falloffStart: 255, rangeStart: 285, rangeEnd: 315, falloffEnd: 345)
        }
    }
    static let colorRanges = ColorRange.allCases.filter { $0 != .master }
}

/// A hue band in degrees, wrapping at 360: full strength between `rangeStart` and
/// `rangeEnd`, fading to nothing at `falloffStart` and `falloffEnd`.
nonisolated struct HueBand: Equatable, Sendable, Codable {
    var falloffStart: Double
    var rangeStart: Double
    var rangeEnd: Double
    var falloffEnd: Double

    /// Degrees from `from` forward to `to`, always 0…360.
    static func forward(_ from: Double, _ to: Double) -> Double {
        let delta = (to - from).truncatingRemainder(dividingBy: 360)
        return delta < 0 ? delta + 360 : delta
    }

    /// How strongly this band claims a hue: 1 inside the range, ramping linearly through
    /// each falloff shoulder, 0 outside. Wraparound is handled by measuring forward.
    func weight(of hue: Double) -> Double {
        let span = Self.forward(falloffStart, falloffEnd)
        guard span > 0 else { return 1 } // Master covers everything.
        let position = Self.forward(falloffStart, hue)
        guard position <= span else { return 0 }
        let rampIn = Self.forward(falloffStart, rangeStart)
        let plateauEnd = Self.forward(falloffStart, rangeEnd)
        if position < rampIn { return rampIn > 0 ? position / rampIn : 1 }
        if position <= plateauEnd { return 1 }
        let rampOut = span - plateauEnd
        return rampOut > 0 ? (span - position) / rampOut : 1
    }

    var handles: [Double] { [falloffStart, rangeStart, rangeEnd, falloffEnd] }

    /// A band centered on one hue, keeping this band's core and shoulder widths.
    func centered(on hue: Double) -> HueBand {
        let core = Self.forward(rangeStart, rangeEnd)
        let leading = Self.forward(falloffStart, rangeStart)
        let trailing = Self.forward(rangeEnd, falloffEnd)
        func wrap(_ value: Double) -> Double {
            let remainder = value.truncatingRemainder(dividingBy: 360)
            return remainder < 0 ? remainder + 360 : remainder
        }
        let start = wrap(hue - core / 2)
        return HueBand(falloffStart: wrap(start - leading), rangeStart: start,
                       rangeEnd: wrap(start + core), falloffEnd: wrap(start + core + trailing))
    }

    /// Widens the band so this hue is fully inside it, moving whichever edge is nearer.
    mutating func include(_ hue: Double) {
        guard weight(of: hue) < 1 else { return }
        let shoulderIn = Self.forward(falloffStart, rangeStart)
        let shoulderOut = Self.forward(rangeEnd, falloffEnd)
        let beforeStart = Self.forward(hue, rangeStart)
        let afterEnd = Self.forward(rangeEnd, hue)
        if beforeStart <= afterEnd {
            rangeStart = hue
            falloffStart = hue - shoulderIn
        } else {
            rangeEnd = hue
            falloffEnd = hue + shoulderOut
        }
        normalize()
    }

    /// Narrows the band so this hue falls outside it entirely, shoulder included.
    mutating func exclude(_ hue: Double) {
        guard weight(of: hue) > 0 else { return }
        let shoulderIn = Self.forward(falloffStart, rangeStart)
        let shoulderOut = Self.forward(rangeEnd, falloffEnd)
        let fromStart = Self.forward(falloffStart, hue)
        let toEnd = Self.forward(hue, falloffEnd)
        if fromStart <= toEnd {
            falloffStart = hue + 1
            rangeStart = hue + 1 + shoulderIn
        } else {
            falloffEnd = hue - 1
            rangeEnd = hue - 1 - shoulderOut
        }
        normalize()
    }

    /// Keeps all four handles in 0…360 and the band under a full circle.
    private mutating func normalize() {
        func wrap(_ value: Double) -> Double {
            let remainder = value.truncatingRemainder(dividingBy: 360)
            return remainder < 0 ? remainder + 360 : remainder
        }
        falloffStart = wrap(falloffStart); rangeStart = wrap(rangeStart)
        rangeEnd = wrap(rangeEnd); falloffEnd = wrap(falloffEnd)
        if Self.forward(falloffStart, falloffEnd) > 350 {
            falloffEnd = wrap(falloffStart + 350)
        }
    }

    /// Moves one handle, keeping the four in order and the band under a full circle.
    mutating func setHandle(_ index: Int, to degrees: Double) {
        var updated = self
        let value = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch index {
        case 0: updated.falloffStart = value
        case 1: updated.rangeStart = value
        case 2: updated.rangeEnd = value
        default: updated.falloffEnd = value
        }
        let span = Self.forward(updated.falloffStart, updated.falloffEnd)
        let toStart = Self.forward(updated.falloffStart, updated.rangeStart)
        let toEnd = Self.forward(updated.falloffStart, updated.rangeEnd)
        guard span > 1, span <= 350, toStart <= toEnd, toEnd <= span else { return }
        self = updated
    }
}

nonisolated struct RangeAdjustment: Equatable, Sendable, Codable {
    var hue: Double = 0
    var saturation: Double = 0
    var lightness: Double = 0
}

/// Hue is −180…180 (0…360 when colorizing), Saturation −100…100 (0…100 colorizing),
/// Lightness −100…100. Each color range keeps its own values; Master applies everywhere.
nonisolated struct HueSaturationSettings: Equatable, Sendable, Codable {
    /// Which range the sliders and spectrum edit.
    var range: ColorRange = .master
    var colorize = false
    /// Applies the selected range to everything *outside* its band instead.
    var invertRange = false
    var adjustments: [ColorRange: RangeAdjustment] = [:]
    var bands: [ColorRange: HueBand] = Dictionary(uniqueKeysWithValues: ColorRange.allCases.map { ($0, $0.defaultBand) })

    init(hue: Double = 0, saturation: Double = 0, lightness: Double = 0, colorize: Bool = false,
         range: ColorRange = .master) {
        self.range = range
        self.colorize = colorize
        adjustments[range] = RangeAdjustment(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// The sliders read and write the selected range.
    var hue: Double {
        get { adjustments[range]?.hue ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].hue = newValue }
    }
    var saturation: Double {
        get { adjustments[range]?.saturation ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].saturation = newValue }
    }
    var lightness: Double {
        get { adjustments[range]?.lightness ?? 0 }
        set { adjustments[range, default: RangeAdjustment()].lightness = newValue }
    }
    var band: HueBand {
        get { bands[range] ?? range.defaultBand }
        set { bands[range] = newValue }
    }

    /// Photoshop's starting point when Colorize is switched on.
    static let colorizeStart = HueSaturationSettings(hue: 0, saturation: 25, lightness: 0, colorize: true)
    var isIdentity: Bool { !colorize && adjustments.values.allSatisfy { $0 == RangeAdjustment() } }

    /// How much a range applies to one hue: Master everywhere, others through their band.
    func weight(of colorRange: ColorRange, hue: Double) -> Double {
        guard colorRange != .master else { return 1 }
        let weight = (bands[colorRange] ?? colorRange.defaultBand).weight(of: hue)
        return invertRange && colorRange == range ? 1 - weight : weight
    }
}
