import Foundation

// The flat color adjustments the manifest stores: Exposure, Gradient Map, Black & White,
// Color Balance and Grain, plus the shared AdjustmentColor. Their `normalized` values and
// validity rules are pure math; the C pixel kernels that apply them stay in the app.

/// The clamp behind the adjustment settings' `normalized` values: non-finite input falls back to
/// the default. (The settings that render through the app's own pixel pipeline share the same
/// rule via ImageAdjustmentPixels, which also owns that pipeline.)
private func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}

/// A straight sRGB color stored with an adjustment, 0–1 per channel.
nonisolated struct AdjustmentColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
    init(_ color: PaletteColor) { self.init(red: Double(color.red), green: Double(color.green), blue: Double(color.blue)) }
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var clamped: Self {
        Self(red: clamp(red, 0...1, 0), green: clamp(green, 0...1, 0), blue: clamp(blue, 0...1, 0))
    }
}

/// Photoshop's Exposure: `exposure` (stops) scales linear light and `offset` shifts it, then gamma
/// correction bends the result. The same curve runs on every channel; alpha is kept.
nonisolated struct ExposureSettings: Codable, Equatable, Sendable {
    static let exposureRange: ClosedRange<Double> = -20...20
    static let offsetRange: ClosedRange<Double> = -0.5...0.5
    static let gammaRange: ClosedRange<Double> = 0.01...9.99
    /// Stops of light, −20…20.
    var exposure: Double = 0
    /// Added in linear light, −0.5…0.5: negative deepens the shadows, positive lifts them.
    var offset: Double = 0
    /// Gamma correction, 0.01…9.99; above 1 brightens the midtones.
    var gamma: Double = 1
    var isValid: Bool { Self.exposureRange.contains(exposure) && Self.offsetRange.contains(offset) && Self.gammaRange.contains(gamma) }
    var normalized: Self {
        Self(exposure: clamp(exposure, Self.exposureRange, 0),
             offset: clamp(offset, Self.offsetRange, 0),
             gamma: clamp(gamma, Self.gammaRange, 1))
    }
    /// Each channel's output (0–1) for each input byte, decoded to linear light and encoded back.
    var table: [Float] {
        let scale = pow(2, exposure)
        return (0...255).map { index in
            let encoded = Double(index) / 255
            var linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            linear = pow(max(0, linear * scale + offset), 1 / gamma)
            let output = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
            return Float(min(1, max(0, output)))
        }
    }
}

/// Gradient Map: each pixel's brightness picks a color between `shadows` and `highlights` (the other
/// way round when reversed); alpha is kept.
nonisolated struct GradientMapSettings: Codable, Equatable, Sendable {
    var shadows = AdjustmentColor(red: 0, green: 0, blue: 0)
    var highlights = AdjustmentColor(red: 1, green: 1, blue: 1)
    var reversed = false
    var isValid: Bool { shadows.isValid && highlights.isValid }
    var normalized: Self {
        var result = self
        result.shadows = shadows.clamped
        result.highlights = highlights.clamped
        return result
    }
    /// The colors for the darkest and lightest tones, in the order they apply.
    var ends: (dark: AdjustmentColor, light: AdjustmentColor) { reversed ? (highlights, shadows) : (shadows, highlights) }
}

/// Black & White, as Photoshop's is: not a desaturation, but a choice of how bright each family of
/// colors becomes in gray. Reds at 40% and yellows at 60% is why a default conversion keeps skin and
/// foliage apart where a plain luminance flattens them.
nonisolated struct BlackWhiteSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -200...300
    /// Photoshop's defaults.
    var reds: Double = 40
    var yellows: Double = 60
    var greens: Double = 40
    var cyans: Double = 60
    var blues: Double = 20
    var magentas: Double = 80
    /// Color the result while keeping its tones, for a sepia or a cyanotype.
    var tint = false
    var tintHue: Double = 40
    var tintSaturation: Double = 20
    var isValid: Bool {
        [reds, yellows, greens, cyans, blues, magentas].allSatisfy { $0.isFinite && Self.range.contains($0) }
            && tintHue.isFinite && (0...360).contains(tintHue)
            && tintSaturation.isFinite && (0...100).contains(tintSaturation)
    }
}

/// Color Balance: shifts color towards one end of each opposing pair, separately for shadows,
/// midtones and highlights. Preserve Luminosity puts each pixel's brightness back afterwards, so a
/// warm cast doesn't also lighten the picture.
nonisolated struct ColorBalanceSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -100...100
    var shadowCyanRed: Double = 0
    var shadowMagentaGreen: Double = 0
    var shadowYellowBlue: Double = 0
    var midCyanRed: Double = 0
    var midMagentaGreen: Double = 0
    var midYellowBlue: Double = 0
    var highlightCyanRed: Double = 0
    var highlightMagentaGreen: Double = 0
    var highlightYellowBlue: Double = 0
    var preserveLuminosity = true
    private var all: [Double] {
        [shadowCyanRed, shadowMagentaGreen, shadowYellowBlue,
         midCyanRed, midMagentaGreen, midYellowBlue,
         highlightCyanRed, highlightMagentaGreen, highlightYellowBlue]
    }
    var isValid: Bool { all.allSatisfy { $0.isFinite && Self.range.contains($0) } }
    var isIdentity: Bool { all.allSatisfy { $0 == 0 } }
}

/// Film grain: brightness noise, strongest in the midtones. Its pattern is fixed in document space by
/// `seed`, so it stays put as the canvas pans or redraws part of the image.
nonisolated struct GrainSettings: Codable, Equatable, Sendable {
    static let amountRange: ClosedRange<Double> = 0...100
    static let sizeRange: ClosedRange<Double> = 0.5...20
    static let roughnessRange: ClosedRange<Double> = 0...100
    /// Strength, 0–100.
    var amount: Double = 25
    /// Grain scale in document pixels, 0.5–20.
    var size: Double = 1.5
    /// 0–100: how much smaller, irregular detail roughens the main grain particles.
    var roughness: Double = 50
    var seed: UInt32 = 0
    var isValid: Bool { Self.amountRange.contains(amount) && Self.sizeRange.contains(size) && Self.roughnessRange.contains(roughness) }
    var normalized: Self {
        var result = self
        result.amount = clamp(amount, Self.amountRange, 25)
        result.size = clamp(size, Self.sizeRange, 1.5)
        result.roughness = clamp(roughness, Self.roughnessRange, 50)
        return result
    }
}
