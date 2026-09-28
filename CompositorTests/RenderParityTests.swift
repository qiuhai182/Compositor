import Testing
@testable import Compositor

/// Both renderers, the same `Renderer` calls, on macOS: the software renderer's blend math and
/// resampling have to track what Core Graphics actually draws — including the modes Core Graphics
/// can't compute, which go through Core Image via `SeparableBlend`, exactly as the exporter draws.
///
/// The cases keep resampling from muddying the comparison. Solid colors survive every shrink (and
/// the exporter's Lanczos halvings) exactly, so the matrix below exercises the whole pipeline —
/// transforms, masks, opacity, blend routing — without filter differences. The gradient runs at
/// one-to-one, where neither backend resamples at all, so it isolates the blend math over many
/// color pairs. Enlargement is deliberately absent: Core Graphics and the software renderer
/// upsample with different filters, a documented difference, as is nearest beyond one-to-one.
struct RenderParityTests {
    private let canvas = 20
    private let backdrop = PixelBuffer.Color(red: 102, green: 150, blue: 89, alpha: 255)

    /// A 160×160 layer keeps the canvas covered with room to spare even at a quarter scale and a
    /// 30° turn, so every canvas pixel is an interior sample in both backends (Core Graphics
    /// antialiases a layer's edges; the software renderer doesn't). Each channel sweeps its own
    /// band, so no pixel has two equal channels and the component modes' channel ordering stays
    /// unambiguous; no channel can sum with the backdrop to 255, so hard mix's threshold never
    /// lands exactly on a sample where float rounding could tip it either way.
    private func gradientSource() -> PixelBuffer {
        var source = PixelBuffer(width: 160, height: 160)
        for y in 0..<160 {
            for x in 0..<160 {
                source[x, y] = (UInt8(40 + (x + y) * 20 / 160), UInt8(110 + y * 40 / 160),
                                UInt8(170 + x * 40 / 160), 255)
            }
        }
        return source
    }

    private func drawBoth(_ source: PixelBuffer, _ transform: LayerTransform, _ mode: LayerBlendMode,
                          _ opacity: Double, _ mask: PixelBuffer?) -> (software: PixelBuffer, cg: PixelBuffer) {
        var software = SoftwareRenderer()
        software.begin(width: canvas, height: canvas, background: backdrop)
        software.draw(source, transform: transform, blendMode: mode, opacity: opacity, mask: mask)
        var cg = CGRenderer()
        cg.begin(width: canvas, height: canvas, background: backdrop)
        cg.draw(source, transform: transform, blendMode: mode, opacity: opacity, mask: mask)
        return (software.finish(), cg.finish())
    }

    private func worstDiff(_ software: PixelBuffer, _ cg: PixelBuffer) -> Int {
        precondition(software.width == cg.width && software.height == cg.height)
        var worst = 0
        for y in 0..<software.height {
            for x in 0..<software.width {
                let a = software[x, y], b = cg[x, y]
                for pair in [(a.red, b.red), (a.green, b.green), (a.blue, b.blue), (a.alpha, b.alpha)] {
                    worst = max(worst, abs(Int(pair.0) - Int(pair.1)))
                }
            }
        }
        return worst
    }

    /// The component modes and the two lights whose formulas Core Graphics keeps to itself round
    /// differently enough to deserve a wider margin; everything else must agree almost exactly.
    private func tolerance(_ mode: LayerBlendMode) -> Int {
        switch mode {
        case .hue, .saturation, .color, .luminosity, .softLight, .vividLight, .hardMix: 6
        default: 2
        }
    }

    @Test func solidLayersMatchCoreGraphicsAcrossTheMatrix() {
        var source = PixelBuffer(width: 160, height: 160)
        source.fill(red: 150, green: 102, blue: 51, alpha: 255)
        var mask = PixelBuffer(width: 64, height: 64)
        mask.fill(red: 0, green: 0, blue: 0, alpha: 128)
        var worst = 0
        var worstLabel = ""
        for mode in LayerBlendMode.allCases {
            for opacity in [1.0, 0.5] {
                for scale in [CGFloat(1), 0.5, 0.25] {
                    let side = 160 * scale
                    for rotation in [CGFloat(0), 30] {
                        for masked in [false, true] {
                            let transform = LayerTransform(origin: CGPoint(x: 10 - side / 2, y: 10 - side / 2),
                                                           size: CGSize(width: side, height: side),
                                                           rotation: rotation, sampling: .smooth)
                            let (software, cg) = drawBoth(source, transform, mode, opacity, masked ? mask : nil)
                            let diff = worstDiff(software, cg)
                            let label = "\(mode.rawValue), opacity \(opacity), scale \(scale), rotation \(rotation)\(masked ? ", masked" : "")"
                            if diff > worst { worst = diff; worstLabel = label }
                            #expect(diff <= tolerance(mode), "\(label): worst channel differs by \(diff)")
                        }
                    }
                }
            }
        }
        print("Solid matrix: worst diff \(worst) at \(worstLabel)")
    }

    @Test func gradientLayersMatchCoreGraphicsOneToOne() {
        let source = gradientSource()
        let transform = LayerTransform(origin: CGPoint(x: -70, y: -70), size: CGSize(width: 160, height: 160),
                                       sampling: .smooth)
        var worst = 0
        var worstLabel = ""
        for mode in LayerBlendMode.allCases {
            for opacity in [1.0, 0.5] {
                let (software, cg) = drawBoth(source, transform, mode, opacity, nil)
                let diff = worstDiff(software, cg)
                if diff > worst { worst = diff; worstLabel = "\(mode.rawValue), opacity \(opacity)" }
                #expect(diff <= tolerance(mode), "\(mode.rawValue), opacity \(opacity): worst channel differs by \(diff)")
            }
        }
        print("Gradient, one to one: worst diff \(worst) at \(worstLabel)")
    }

    /// Nearest matches too when nothing is resampled: one-to-one reads whole texels in both backends.
    @Test func nearestLayersMatchCoreGraphicsOneToOne() {
        let source = gradientSource()
        let transform = LayerTransform(origin: CGPoint(x: -70, y: -70), size: CGSize(width: 160, height: 160),
                                       sampling: .nearest)
        var worst = 0
        var worstLabel = ""
        for mode in LayerBlendMode.allCases {
            let (software, cg) = drawBoth(source, transform, mode, 1, nil)
            let diff = worstDiff(software, cg)
            if diff > worst { worst = diff; worstLabel = mode.rawValue }
            #expect(diff <= tolerance(mode), "\(mode.rawValue): worst channel differs by \(diff)")
        }
        print("Nearest, one to one: worst diff \(worst) at \(worstLabel)")
    }
}
