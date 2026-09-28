import Foundation

/// Bloom / Glow, in Core Image's `CIBloom` shape: the image's bright areas pass through a soft
/// knee, spread with the Gaussian blur, and are added back on top scaled by `intensity`.
nonisolated enum Bloom {
    /// `intensity` scales the added glow (the app's Amount of 50 maps to 1), `radius` is the
    /// spread in pixels. Only color is added: alpha stays as it was, the glow stays inside the
    /// layer's own alpha, and each channel is clamped back to its pixel's alpha, which the
    /// addition can push past.
    static func apply(intensity: Double, radius: Double, to input: PixelBuffer) -> PixelBuffer {
        guard intensity > 0, radius >= 0.5, input.width >= 1, input.height >= 1 else { return input }
        // The bright pass keeps what is above the knee with a smoothstep ramp across the softness
        // band, so a bloom's edge moves with brightness instead of snapping at one level.
        let knee = 0.5, softness = 0.25
        var brightened = input
        for p in stride(from: 0, to: input.data.count, by: 4) {
            let alpha = Double(input.data[p + 3])
            guard alpha > 0 else { continue }
            let red = Double(input.data[p]) / alpha, green = Double(input.data[p + 1]) / alpha
            let blue = Double(input.data[p + 2]) / alpha
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            guard luminance < knee + softness else { continue }
            guard luminance > knee - softness else {
                for c in 0..<3 { brightened.data[p + c] = 0 }
                continue
            }
            let ramp = (luminance - (knee - softness)) / (2 * softness)
            let factor = ramp * ramp * (3 - 2 * ramp)
            for c in 0..<3 { brightened.data[p + c] = UInt8((Double(input.data[p + c]) * factor).rounded()) }
        }
        let spread = GaussianBlur.apply(radius, to: brightened)
        var result = input
        for p in stride(from: 0, to: input.data.count, by: 4) {
            let alpha = Double(input.data[p + 3])
            guard alpha > 0 else { continue }
            for c in 0..<3 {
                let value = Double(input.data[p + c]) + Double(spread.data[p + c]) * intensity
                result.data[p + c] = UInt8(min(alpha, max(0, value)).rounded())
            }
        }
        return result
    }
}
