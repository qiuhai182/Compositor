import Foundation

/// The documented blend-mode math (W3C Compositing and Blending Level 1), shared by every backend
/// that composites by hand — the software renderer today, and the macOS app's Core Graphics only
/// ever as the reference those formulas must match. All channel values are straight (not
/// premultiplied) and in 0...1; alpha handling follows the spec's general compositing equation, so
/// callers pass straight colors and alphas and store the result premultiplied (see `composite`).
nonisolated enum BlendMath {
    typealias Color = (red: Double, green: Double, blue: Double)

    /// The backdrop's relative luminance with the spec's 0.3 / 0.59 / 0.11 weights.
    static func luminance(_ color: Color) -> Double {
        0.3 * color.red + 0.59 * color.green + 0.11 * color.blue
    }

    /// Pulls a color's channels back into 0...1 by scaling their spread around the luminance,
    /// which keeps the luminance the color was set to.
    static func clipColor(_ color: Color) -> Color {
        let l = luminance(color)
        let minC = min(color.red, color.green, color.blue)
        let maxC = max(color.red, color.green, color.blue)
        var result = color
        if minC < 0 {
            let factor = l / (l - minC)
            result.red = l + (result.red - l) * factor
            result.green = l + (result.green - l) * factor
            result.blue = l + (result.blue - l) * factor
        }
        if maxC > 1 {
            let factor = (1 - l) / (maxC - l)
            result.red = l + (result.red - l) * factor
            result.green = l + (result.green - l) * factor
            result.blue = l + (result.blue - l) * factor
        }
        return result
    }

    /// Moves a color's luminance to `l`, clipping chroma if the shift leaves the gamut.
    static func setLum(_ color: Color, _ l: Double) -> Color {
        let d = l - luminance(color)
        return clipColor((color.red + d, color.green + d, color.blue + d))
    }

    /// The spread between a color's strongest and weakest channel.
    static func saturation(_ color: Color) -> Double {
        max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
    }

    /// Rescales a color so its strongest channel takes `s` whole, its weakest drops to 0, and the
    /// middle keeps its place in between. An achromatic color has no direction to stretch along,
    /// so it comes out black.
    static func setSat(_ color: Color, _ s: Double) -> Color {
        let minC = min(color.red, color.green, color.blue)
        let maxC = max(color.red, color.green, color.blue)
        guard maxC > minC else { return (0, 0, 0) }
        func scaled(_ c: Double) -> Double {
            if c == maxC { return s }
            if c == minC { return 0 }
            return (c - minC) * s / (maxC - minC)
        }
        return (scaled(color.red), scaled(color.green), scaled(color.blue))
    }

    /// The blend function B(Cb, Cs) for the per-channel-separable modes. The four component modes
    /// (hue, saturation, color, luminosity) mix all three channels at once — call `blend(_:backdrop:source:)`
    /// for those. The spec's edge rules come first, then the formula.
    static func blend(_ mode: LayerBlendMode, _ backdrop: Double, _ source: Double) -> Double {
        switch mode {
        case .normal: source
        case .darken: min(backdrop, source)
        case .multiply: backdrop * source
        case .colorBurn:
            if backdrop == 1 { 1 }
            else if source == 0 { 0 }
            else { 1 - min(1, (1 - backdrop) / source) }
        case .linearBurn: max(0, backdrop + source - 1)
        case .lighten: max(backdrop, source)
        case .screen: backdrop + source - backdrop * source
        case .colorDodge:
            if backdrop == 0 { 0 }
            else if source == 1 { 1 }
            else { min(1, backdrop / (1 - source)) }
        case .linearDodge: min(1, backdrop + source)
        case .overlay: hardLight(source, backdrop)
        case .softLight: softLight(backdrop, source)
        case .hardLight: hardLight(backdrop, source)
        case .vividLight: vividLight(backdrop, source)
        case .linearLight: min(1, max(0, backdrop + 2 * source - 1))
        case .pinLight: source <= 0.5 ? min(backdrop, 2 * source) : max(backdrop, 2 * source - 1)
        case .hardMix: vividLight(backdrop, source) <= 0.5 ? 0 : 1
        case .difference: abs(backdrop - source)
        case .exclusion: backdrop + source - 2 * backdrop * source
        case .subtract: max(0, backdrop - source)
        case .divide:
            if source == 0 { backdrop == 0 ? 0 : 1 }
            else { min(1, backdrop / source) }
        case .hue, .saturation, .color, .luminosity:
            0 // Never reached through `blend(_:backdrop:source:)`, which computes these on all channels.
        }
    }

    /// Hard light: multiply below half strength, screen above.
    private static func hardLight(_ backdrop: Double, _ source: Double) -> Double {
        source <= 0.5 ? 2 * source * backdrop : 1 - 2 * (1 - source) * (1 - backdrop)
    }

    /// Soft light, per the spec: a gentle shift toward the source, with the response curve D(Cb).
    private static func softLight(_ backdrop: Double, _ source: Double) -> Double {
        func low(_ backdrop: Double) -> Double { ((16 * backdrop - 12) * backdrop + 4) * backdrop }
        func high(_ backdrop: Double) -> Double { backdrop.squareRoot() }
        if source <= 0.5 {
            return backdrop - (1 - 2 * source) * backdrop * (1 - backdrop)
        }
        let g = backdrop <= 0.25 ? low(backdrop) : high(backdrop)
        return backdrop + (2 * source - 1) * (g - backdrop)
    }

    /// Vivid light: color burn below half strength, color dodge above, with each mode's own edge
    /// rules making the extremes (a white backdrop under black, a black one under white) stay put.
    private static func vividLight(_ backdrop: Double, _ source: Double) -> Double {
        if source <= 0.5 {
            let burn = 2 * source
            if backdrop == 1 { return 1 }
            if burn == 0 { return 0 }
            return max(0, 1 - (1 - backdrop) / burn)
        }
        let dodge = 2 * source - 1
        if backdrop == 0 { return 0 }
        if dodge == 1 { return 1 }
        return min(1, backdrop / (1 - dodge))
    }

    /// The blended color B(Cb, Cs) for every mode: separable ones channel by channel, and the four
    /// component modes by recombining hue, saturation and luminosity between the two colors.
    static func blend(_ mode: LayerBlendMode, backdrop: Color, source: Color) -> Color {
        switch mode {
        case .hue: setLum(setSat(source, saturation(backdrop)), luminance(backdrop))
        case .saturation: setLum(setSat(backdrop, saturation(source)), luminance(backdrop))
        case .color: setLum(source, luminance(backdrop))
        case .luminosity: setLum(backdrop, luminance(source))
        default:
            (blend(mode, backdrop.red, source.red),
             blend(mode, backdrop.green, source.green),
             blend(mode, backdrop.blue, source.blue))
        }
    }

    /// Composites one pixel: `backdrop` and `source` are straight colors with alphas in 0...1. The
    /// spec's general equation — co = (1−αb)·αs·Cs + (1−αs)·αb·Cb + αs·αb·B(Cb, Cs), with
    /// αo = αs + αb·(1−αs) — is already the premultiplied result, which is what comes back.
    static func composite(mode: LayerBlendMode,
                          backdrop: (color: Color, alpha: Double),
                          source: (color: Color, alpha: Double)) -> (color: Color, alpha: Double) {
        let alphaOut = source.alpha + backdrop.alpha * (1 - source.alpha)
        guard source.alpha > 0 else {
            return ((backdrop.color.red * backdrop.alpha,
                     backdrop.color.green * backdrop.alpha,
                     backdrop.color.blue * backdrop.alpha), alphaOut)
        }
        let blended = blend(mode, backdrop: backdrop.color, source: source.color)
        func out(_ cb: Double, _ cs: Double, _ b: Double) -> Double {
            (1 - backdrop.alpha) * source.alpha * cs
                + (1 - source.alpha) * backdrop.alpha * cb
                + source.alpha * backdrop.alpha * b
        }
        let color = (out(backdrop.color.red, source.color.red, blended.red),
                     out(backdrop.color.green, source.color.green, blended.green),
                     out(backdrop.color.blue, source.color.blue, blended.blue))
        return (color, alphaOut)
    }
}
