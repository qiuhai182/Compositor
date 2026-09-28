import Testing
@testable import CompositorCore

/// The blend math against hand-worked values, straight from the W3C formulas — this is the
/// reference the software renderer composites with and the parity tests hold Core Graphics to.
struct BlendMathTests {
    /// One blended channel per hand-worked case; the per-channel modes only ever see (Cb, Cs) pairs.
    @Test func perChannelModesMatchTheFormulas() {
        let cases: [(mode: LayerBlendMode, backdrop: Double, source: Double, expected: Double)] = [
            (.normal, 0.3, 0.7, 0.7),
            (.darken, 0.3, 0.6, 0.3), (.lighten, 0.3, 0.6, 0.6),
            (.multiply, 0.5, 0.5, 0.25), (.multiply, 0.2, 0.9, 0.18),
            (.screen, 0.5, 0.5, 0.75), (.screen, 0.2, 0.3, 0.44),
            (.overlay, 0.3, 0.6, 0.36), (.overlay, 0.8, 0.25, 0.7), (.overlay, 0.5, 0.4, 0.4),
            (.hardLight, 0.5, 0.25, 0.25), (.hardLight, 0.5, 0.75, 0.75),
            (.colorDodge, 0.25, 0.5, 0.5), (.colorDodge, 0.5, 1, 1), (.colorDodge, 0, 0.8, 0),
            (.colorBurn, 0.75, 0.5, 0.5), (.colorBurn, 1, 0.2, 1), (.colorBurn, 0.3, 0, 0),
            (.linearBurn, 0.6, 0.6, 0.2), (.linearBurn, 0.2, 0.3, 0),
            (.linearDodge, 0.6, 0.6, 1), (.linearDodge, 0.2, 0.3, 0.5),
            (.vividLight, 0.5, 0.75, 1), (.vividLight, 0.5, 0.25, 0),
            (.vividLight, 1, 0, 1), (.vividLight, 0, 1, 0), (.vividLight, 0.6, 0.4, 0.5),
            (.linearLight, 0.5, 0.75, 1), (.linearLight, 0.5, 0.25, 0), (.linearLight, 0.2, 0.3, 0),
            (.pinLight, 0.6, 0.3, 0.6), (.pinLight, 0.2, 0.3, 0.2),
            (.pinLight, 0.2, 0.8, 0.6), (.pinLight, 0.6, 0.8, 0.6),
            (.hardMix, 0.5, 0.75, 1), (.hardMix, 0.5, 0.25, 0), (.hardMix, 0.6, 0.4, 0),
            (.difference, 0.8, 0.3, 0.5), (.exclusion, 0.8, 0.3, 0.62),
            (.subtract, 0.8, 0.3, 0.5), (.subtract, 0.2, 0.5, 0),
            (.divide, 0.25, 0.5, 0.5), (.divide, 0.5, 0.5, 1), (.divide, 0.5, 0, 1), (.divide, 0, 0, 0),
            // Soft light by hand: g(0.25) = 0.5, so 0.25 + (2·0.6 − 1)·(0.5 − 0.25) = 0.3;
            // and below half strength, 0.8 − (1 − 0.4)·0.8·0.2 = 0.704.
            (.softLight, 0.25, 0.6, 0.3), (.softLight, 0.8, 0.2, 0.704), (.softLight, 0.5, 0.5, 0.5),
        ]
        for (mode, backdrop, source, expected) in cases {
            #expect(abs(BlendMath.blend(mode, backdrop, source) - expected) < 1e-12,
                    "\(mode) B(\(backdrop), \(source)) should be \(expected)")
        }
    }

    /// Overlay is hard light with the parameters swapped, so it's the backdrop that decides the branch.
    @Test func overlaySwapsHardLightsArguments() {
        for (backdrop, source) in [(0.2, 0.9), (0.8, 0.1), (0.4, 0.6), (0.6, 0.4)] {
            #expect(BlendMath.blend(.overlay, backdrop, source) == BlendMath.blend(.hardLight, source, backdrop))
        }
    }

    /// The component modes recombine channels; check exact values and the luminance they preserve.
    @Test func componentModesRecombineChannels() {
        let backdrop = (0.2, 0.4, 0.6)   // luminance 0.362, saturation 0.4
        let source = (0.8, 0.2, 0.2)     // luminance 0.38, saturation 0.6

        // Hue: the source's hue at the backdrop's saturation and luminance.
        let hue = BlendMath.blend(.hue, backdrop: backdrop, source: source)
        #expect(abs(hue.red - 0.642) < 1e-12 && abs(hue.green - 0.242) < 1e-12 && abs(hue.blue - 0.242) < 1e-12)
        #expect(abs(BlendMath.luminance(hue) - BlendMath.luminance(backdrop)) < 1e-12)

        // Saturation: the backdrop's channels re-stretched to the source's saturation.
        let saturation = BlendMath.blend(.saturation, backdrop: backdrop, source: source)
        #expect(abs(saturation.red - 0.119) < 1e-12 && abs(saturation.green - 0.419) < 1e-12
            && abs(saturation.blue - 0.719) < 1e-12)
        #expect(abs(BlendMath.saturation(saturation) - BlendMath.saturation(source)) < 1e-12)
        #expect(abs(BlendMath.luminance(saturation) - BlendMath.luminance(backdrop)) < 1e-12)

        // Color: the source at the backdrop's luminance; luminosity: the backdrop at the source's.
        let color = BlendMath.blend(.color, backdrop: backdrop, source: source)
        #expect(abs(color.red - 0.782) < 1e-12 && abs(color.green - 0.182) < 1e-12 && abs(color.blue - 0.182) < 1e-12)
        let luminosity = BlendMath.blend(.luminosity, backdrop: backdrop, source: (0.2, 0.2, 0.2))
        #expect(abs(luminosity.red - 0.038) < 1e-12 && abs(luminosity.green - 0.238) < 1e-12
            && abs(luminosity.blue - 0.438) < 1e-12)
        #expect(abs(BlendMath.luminance(luminosity) - 0.2) < 1e-12)
    }

    /// ClipColor keeps the luminance while pulling the channels into gamut.
    @Test func clippingPreservesLuminance() {
        let outOfGamut = (0.638, 0.838, 1.038)  // luminance exactly 0.8
        let clipped = BlendMath.clipColor(outOfGamut)
        #expect(abs(clipped.blue - 1) < 1e-12)
        #expect(abs(BlendMath.luminance(clipped) - BlendMath.luminance(outOfGamut)) < 1e-12)
    }

    /// The general compositing equation, by hand: 50% red over 50% blue comes out 75% alpha with
    /// the premultiplied color 0.5 red + 0.25 blue; multiply weighs in the blend term.
    @Test func compositingWeightsSourceBackdropAndBlend() {
        let normal = BlendMath.composite(mode: .normal, backdrop: ((0, 0, 1), 0.5), source: ((1, 0, 0), 0.5))
        #expect(abs(normal.alpha - 0.75) < 1e-12)
        #expect(abs(normal.color.red - 0.5) < 1e-12 && abs(normal.color.blue - 0.25) < 1e-12)

        let multiply = BlendMath.composite(mode: .multiply, backdrop: ((0.5, 0.5, 0.5), 0.5), source: ((1, 1, 1), 0.5))
        // (1−0.5)·0.5·1 + (1−0.5)·0.5·0.5 + 0.25·0.5 = 0.5 per channel.
        #expect(abs(multiply.color.red - 0.5) < 1e-12 && abs(multiply.alpha - 0.75) < 1e-12)

        // A fully transparent source leaves the premultiplied backdrop alone.
        let clear = BlendMath.composite(mode: .difference, backdrop: ((0.6, 0.4, 0.2), 0.5), source: ((1, 1, 1), 0))
        #expect(abs(clear.color.red - 0.3) < 1e-12 && abs(clear.alpha - 0.5) < 1e-12)
    }
}
