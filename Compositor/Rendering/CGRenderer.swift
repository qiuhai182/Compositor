import CoreGraphics

/// The `Renderer` protocol adapted to Core Graphics, so the macOS app can run the same drawing
/// calls through either backend. Layers go through the existing `LayerRenderer` — and, for the
/// modes Core Graphics can't compute, through `SeparableBlend` — exactly as `ImageExporter` draws
/// them. The bitmap context is flipped at `begin`, so the protocol's y-down center coordinates and
/// first-row-first masks mean the same thing here as they do to the software renderer.
nonisolated struct CGRenderer: Renderer {
    private var context: CGContext?

    /// Explicit because the stored property is private: the synthesized memberwise initializer would be too.
    init() {}

    mutating func begin(width: Int, height: Int, background: PixelBuffer.Color) {
        context = nil
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        // Straight components for the premultiplied background: the bytes divide by the alpha.
        if background.alpha > 0 {
            let alpha = CGFloat(background.alpha) / 255
            let components = [CGFloat(background.red) / 255 / alpha,
                              CGFloat(background.green) / 255 / alpha,
                              CGFloat(background.blue) / 255 / alpha, alpha]
            context.setFillColor(CGColor(colorSpace: space, components: components)!)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        self.context = context
    }

    mutating func draw(_ pixels: PixelBuffer, transform: LayerTransform, blendMode: LayerBlendMode,
                       opacity: Double, mask: PixelBuffer?) {
        guard let context, let image = PlatformImage(pixels: pixels) else { return }
        let layerMask = mask.flatMap(Self.grayImage)
        func drawLayer(_ mode: LayerBlendMode, into target: CGContext) {
            LayerRenderer.draw(image.cgImage, transform: transform, center: transform.center,
                               opacity: opacity, blendMode: mode, mask: layerMask, in: target)
        }
        if SeparableBlend.needsSurface(blendMode),
           SeparableBlend.draw(blendMode, in: context, body: { drawLayer(.normal, into: $0) }) { return }
        drawLayer(blendMode, into: context)
    }

    mutating func finish() -> PixelBuffer {
        guard let context, let image = context.makeImage() else {
            return PixelBuffer(width: 0, height: 0)
        }
        context = nil
        return PlatformImage(cgImage: image).pixels
    }

    /// The mask as an 8-bit gray image for `clip(to:mask:)`: its alpha channel is the coverage,
    /// white showing the layer like every mask PNG the app stores.
    private static func grayImage(_ pixels: PixelBuffer) -> CGImage? {
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        var gray = [UInt8](repeating: 0, count: pixels.width * pixels.height)
        for row in 0..<pixels.height {
            for column in 0..<pixels.width {
                gray[row * pixels.width + column] = pixels.data[pixels.index(x: column, y: row) + 3]
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: pixels.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
