import Testing
@testable import CompositorCore

/// The software renderer's geometry and sampling, one 4×4 canvas and one 2×2 source at a time:
/// where texels land under rotation and flips, how nearest differs from bilinear, and how opacity,
/// masks and blend modes reach the pixels. Every expected value below is worked by hand.
struct SoftwareRendererTests {
    /// Packs row-major pixels into a buffer.
    private func buffer(_ pixels: [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)],
                        width: Int, height: Int) -> PixelBuffer {
        var result = PixelBuffer(width: width, height: height)
        for (index, pixel) in pixels.enumerated() {
            result[index % width, index / width] = pixel
        }
        return result
    }

    private func pixel(_ buffer: PixelBuffer, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let value = buffer[x, y]
        return (value.red, value.green, value.blue, value.alpha)
    }

    private func render(_ source: PixelBuffer, transform: LayerTransform,
                        background: PixelBuffer.Color = .clear, blendMode: LayerBlendMode = .normal,
                        opacity: Double = 1, mask: PixelBuffer? = nil) -> PixelBuffer {
        var renderer = SoftwareRenderer()
        renderer.begin(width: 4, height: 4, background: background)
        renderer.draw(source, transform: transform, blendMode: blendMode, opacity: opacity, mask: mask)
        return renderer.finish()
    }

    private let texels: [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)] = [
        (255, 0, 0, 255), (0, 255, 0, 255),   // red   green
        (0, 0, 255, 255), (255, 255, 255, 255) // blue  white
    ]

    @Test func identityPlacesTexelsOneToOne() {
        let result = render(buffer(texels, width: 2, height: 2),
                            transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2), sampling: .nearest))
        #expect(pixel(result, 1, 1) == (255, 0, 0, 255))
        #expect(pixel(result, 2, 1) == (0, 255, 0, 255))
        #expect(pixel(result, 1, 2) == (0, 0, 255, 255))
        #expect(pixel(result, 2, 2) == (255, 255, 255, 255))
        #expect(pixel(result, 0, 0) == (0, 0, 0, 0))
        #expect(pixel(result, 3, 3) == (0, 0, 0, 0))
    }

    /// At one-to-one, aligned geometry the bilinear path reads whole texels too.
    @Test func smoothSamplingIsExactOneToOne() {
        let result = render(buffer(texels, width: 2, height: 2),
                            transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2)))
        #expect(pixel(result, 1, 1) == (255, 0, 0, 255))
        #expect(pixel(result, 2, 2) == (255, 255, 255, 255))
        #expect(pixel(result, 0, 0) == (0, 0, 0, 0))
    }

    /// Clockwise 90°: the top-left texel moves to the top-right canvas pixel.
    @Test func quarterTurnRotatesContentClockwise() {
        let result = render(buffer(texels, width: 2, height: 2),
                            transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2),
                                                      rotation: 90, sampling: .nearest))
        #expect(pixel(result, 2, 1) == (255, 0, 0, 255))       // top-left → top-right
        #expect(pixel(result, 2, 2) == (0, 255, 0, 255))       // top-right → bottom-right
        #expect(pixel(result, 1, 2) == (255, 255, 255, 255))   // bottom-right → bottom-left
        #expect(pixel(result, 1, 1) == (0, 0, 255, 255))       // bottom-left → top-left
        #expect(pixel(result, 0, 0) == (0, 0, 0, 0))
        #expect(pixel(result, 3, 1) == (0, 0, 0, 0))
    }

    @Test func flipsMirrorInsideTheLayer() {
        let flippedX = render(buffer(texels, width: 2, height: 2),
                              transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2), flipX: true, sampling: .nearest))
        #expect(pixel(flippedX, 1, 1) == (0, 255, 0, 255))
        #expect(pixel(flippedX, 2, 1) == (255, 0, 0, 255))
        #expect(pixel(flippedX, 2, 2) == (0, 0, 255, 255))
        let flippedY = render(buffer(texels, width: 2, height: 2),
                              transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2), flipY: true, sampling: .nearest))
        #expect(pixel(flippedY, 1, 1) == (0, 0, 255, 255))
        #expect(pixel(flippedY, 1, 2) == (255, 0, 0, 255))
    }

    /// The 2×2 source blown up to the 4×4 layer: nearest steps through whole texels, bilinear
    /// blends — and fades against the transparent border at the layer's outer pixels.
    @Test func nearestAndBilinearUpscaleDiffer() {
        var transform = LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4), sampling: .nearest)
        let nearest = render(buffer(texels, width: 2, height: 2), transform: transform)
        #expect(pixel(nearest, 0, 0) == (255, 0, 0, 255))
        #expect(pixel(nearest, 1, 0) == (255, 0, 0, 255))
        #expect(pixel(nearest, 2, 0) == (0, 255, 0, 255))
        #expect(pixel(nearest, 3, 0) == (0, 255, 0, 255))

        transform.sampling = .smooth
        let smooth = render(buffer(texels, width: 2, height: 2), transform: transform)
        // Corner: the only in-bounds tap is texel(0,0) at weight 0.75·0.75.
        #expect(pixel(smooth, 0, 0) == (143, 0, 0, 143))
        // Second pixel: 0.75·texel(0,0) + 0.25·texel(1,0), still scaled by the 0.75 vertical weight.
        #expect(pixel(smooth, 1, 0) == (143, 48, 0, 191))
    }

    @Test func opacityHalfBlendsWithTheBackground() {
        let source = buffer([(255, 0, 0, 255), (255, 0, 0, 255), (255, 0, 0, 255), (255, 0, 0, 255)], width: 2, height: 2)
        let result = render(source, transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2), sampling: .nearest),
                            background: PixelBuffer.Color(red: 0, green: 0, blue: 255, alpha: 255), opacity: 0.5)
        #expect(pixel(result, 1, 1) == (128, 0, 128, 255))
    }

    /// The mask's alpha is the coverage: its own resolution maps onto the layer's rectangle.
    @Test func maskCoversByItsOwnAlpha() {
        let source = buffer([(255, 0, 0, 255), (255, 0, 0, 255), (255, 0, 0, 255), (255, 0, 0, 255)], width: 2, height: 2)
        var halfHidden = PixelBuffer(width: 2, height: 2)
        halfHidden[0, 0] = (0, 0, 0, 255); halfHidden[1, 0] = (0, 0, 0, 0)
        halfHidden[0, 1] = (0, 0, 0, 255); halfHidden[1, 1] = (0, 0, 0, 0)
        let hidden = render(source, transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2), sampling: .nearest),
                            mask: halfHidden)
        #expect(pixel(hidden, 1, 1) == (255, 0, 0, 255))
        #expect(pixel(hidden, 2, 1) == (0, 0, 0, 0))
        #expect(pixel(hidden, 1, 2) == (255, 0, 0, 255))
        #expect(pixel(hidden, 2, 2) == (0, 0, 0, 0))

        // A finer mask than the source still covers the layer's rectangle, half strength throughout.
        var fine = PixelBuffer(width: 4, height: 4)
        fine.fill(red: 0, green: 0, blue: 0, alpha: 128)
        let half = render(source, transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2), sampling: .nearest),
                          mask: fine)
        #expect(pixel(half, 1, 1) == (128, 0, 0, 128))
        #expect(pixel(half, 2, 2) == (128, 0, 0, 128))
    }

    @Test func blendModesReachTheMath() {
        let source = buffer([(255, 0, 0, 255), (255, 0, 0, 255), (255, 0, 0, 255), (255, 0, 0, 255)], width: 2, height: 2)
        let result = render(source, transform: LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 2), sampling: .nearest),
                            background: PixelBuffer.Color(red: 0, green: 0, blue: 255, alpha: 255), blendMode: .multiply)
        // Red multiplied over blue: every channel multiplies to zero, where normal would keep the red.
        #expect(pixel(result, 1, 1) == (0, 0, 0, 255))
        #expect(pixel(result, 0, 0) == (0, 0, 255, 255))
    }

    @Test func layerEdgesClipToTheCanvas() {
        let result = render(buffer(texels, width: 2, height: 2),
                            transform: LayerTransform(origin: CGPoint(x: 3, y: 3), size: CGSize(width: 2, height: 2), sampling: .nearest))
        #expect(pixel(result, 3, 3) == (255, 0, 0, 255))
        #expect(pixel(result, 2, 3) == (0, 0, 0, 0))
        #expect(pixel(result, 3, 2) == (0, 0, 0, 0))
    }

    @Test func beginFillsTheBackgroundAndEmptyRendersStayEmpty() {
        var renderer = SoftwareRenderer()
        #expect(renderer.finish().width == 0 && renderer.finish().height == 0)
        renderer.begin(width: 2, height: 2, background: .white)
        let blank = renderer.finish()
        #expect(pixel(blank, 0, 0) == (255, 255, 255, 255) && pixel(blank, 1, 1) == (255, 255, 255, 255))
    }
}
