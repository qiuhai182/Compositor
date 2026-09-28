import Foundation

/// The Filter menu's filters that run without Apple frameworks: the three Core Image ones rewritten
/// in pure Swift (Gaussian Blur, Motion Blur, Bloom / Glow) and the four that were always portable
/// C (Add Noise, Vignette, Tonal Contrast, Lens Correction). The raw-value strings match the app's
/// `FilterKind` so a manifest or a tool can name a filter either way. The rest of the menu stays
/// on the app's pipeline for now — the color adjustments through its C kernels behind
/// ImageAdjustmentPixels, Camera Raw through its own grade stack, Remove Background through Vision,
/// Content-Aware Fill through its own kernel and CG plumbing (see docs/cross-platform.md).
nonisolated enum PortableFilter: String, CaseIterable, Sendable {
    case gaussianBlur = "Gaussian Blur"
    case motionBlur = "Motion Blur"
    case addNoise = "Add Noise"
    case vignette = "Vignette"
    case bloomGlow = "Bloom / Glow"
    case tonalContrast = "Tonal Contrast"
    case lensCorrection = "Lens Correction"
}

/// One portable filter's settings — the fields of the app's `FilterSettings` those seven filters
/// read, gathered so the headless pipeline needs nothing from the app tree. The ranges match the
/// app's; callers hand in already-normalized values.
nonisolated struct FilterParameters: Equatable, Sendable {
    /// Gaussian Blur's sigma, in layer pixels.
    var radius: Double = 1
    /// Motion Blur's direction, degrees counterclockwise from horizontal.
    var angle: Double = 0
    /// Motion Blur's streak length, in layer pixels.
    var distance: Double = 10
    /// Add Noise's strength, Photoshop's percentage.
    var amount: Double = 10
    /// Add Noise's speckled (Gaussian) rather than uniform distribution.
    var gaussian = false
    /// Add Noise changes brightness only, the same amount on every channel.
    var monochromatic = false
    var vignetteAmount: Double = 35
    var vignetteColor = AdjustmentColor(red: 0, green: 0, blue: 0)
    var vignetteMidpoint: Double = 50
    var vignetteRoundness: Double = 100
    var vignetteFeather: Double = 60
    var vignetteHighlights: Double = 25
    var bloomAmount: Double = 40
    var bloomRadius: Double = 24
    var tonalAmount: Double = 50
    var tonalRadius: Double = 16
    var tonalShadows: Double = 40
    var tonalMidtones: Double = 60
    var tonalHighlights: Double = 30
    /// Lens Correction's Remove Distortion, −100…100.
    var distortion: Double = 0
    /// Add Noise's random pattern: the same seed gives the same grain.
    var seed: UInt32 = 0
    /// Remove Distortion at ±100 moves the image's corners by this share of their distance from
    /// the center — the same constant the app's filter pipeline uses.
    static let lensStrength = 0.35
}

extension PortableFilter {
    /// Applies the filter to `image` (premultiplied RGBA) and returns the result. The radii are in
    /// layer pixels, so a downscaled preview passes `scale` — preview pixels per layer pixel — to
    /// keep the filter proportionate; Add Noise stays in preview pixels, exactly as the app's
    /// pipeline makes full-size previews of it.
    func render(_ parameters: FilterParameters, scale: Double = 1, to image: PixelBuffer) -> PixelBuffer {
        switch self {
        case .gaussianBlur:
            return GaussianBlur.apply(parameters.radius * scale, to: image)
        case .motionBlur:
            // The streak length is the real one here; only Core Image's sigma-like radius needed
            // the divide-by-root-twelve conversion the app's pipeline applies.
            return MotionBlur.apply(angleDegrees: parameters.angle, distance: parameters.distance * scale, to: image)
        case .addNoise:
            var noisy = image
            PixelKernels.addNoise(to: &noisy, amount: parameters.amount, gaussian: parameters.gaussian,
                                  monochromatic: parameters.monochromatic, seed: parameters.seed)
            return noisy
        case .vignette:
            var framed = image
            PixelKernels.applyVignette(to: &framed, frame: nil, fillsClear: false,
                                       amount: parameters.vignetteAmount, midpoint: parameters.vignetteMidpoint,
                                       roundness: parameters.vignetteRoundness, feather: parameters.vignetteFeather,
                                       highlights: parameters.vignetteHighlights, color: parameters.vignetteColor)
            return framed
        case .bloomGlow:
            return Bloom.apply(intensity: parameters.bloomAmount / 50, radius: parameters.bloomRadius * scale, to: image)
        case .tonalContrast:
            var adjusted = image
            let blurred = GaussianBlur.apply(parameters.tonalRadius * scale, to: image)
            PixelKernels.applyTonalContrast(to: &adjusted, blurred: blurred, amount: parameters.tonalAmount,
                                            shadows: parameters.tonalShadows, midtones: parameters.tonalMidtones,
                                            highlights: parameters.tonalHighlights)
            return adjusted
        case .lensCorrection:
            return PixelKernels.lensDistort(from: image, k: parameters.distortion / 100 * FilterParameters.lensStrength)
        }
    }
}
