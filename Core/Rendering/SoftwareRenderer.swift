import Foundation

/// The pure-Swift renderer: composites PixelBuffers by hand, so the whole pipeline works wherever
/// Swift does. Resampling matches what the macOS renderer asks of Core Graphics when shrinking
/// (bilinear; nearest when asked), blending follows `BlendMath` to the letter. The mask always
/// resamples bilinearly, whatever the layer's own sampling. Every canvas pixel in the layer's
/// bounding box maps back through the transform to a source position, so pixels the layer never
/// reaches cost nothing.
nonisolated struct SoftwareRenderer: Renderer {
    private var target: PixelBuffer?

    /// Explicit because the stored property is private: the synthesized memberwise initializer would be too.
    init() {}

    mutating func begin(width: Int, height: Int, background: PixelBuffer.Color) {
        var buffer = PixelBuffer(width: width, height: height)
        buffer.fill(background)
        target = buffer
    }

    mutating func draw(_ pixels: PixelBuffer, transform: LayerTransform, blendMode: LayerBlendMode,
                       opacity: Double, mask: PixelBuffer?) {
        guard var target else { return }
        defer { self.target = target }
        let layerWidth = transform.size.width, layerHeight = transform.size.height
        guard layerWidth > 0, layerHeight > 0, layerWidth.isFinite, layerHeight.isFinite,
              transform.radians.isFinite, transform.center.x.isFinite, transform.center.y.isFinite,
              opacity > 0, pixels.width > 0, pixels.height > 0 else { return }
        let center = transform.center
        let cos = Foundation.cos(transform.radians), sin = Foundation.sin(transform.radians)
        let opacity = min(1, max(0, opacity))

        // Where the rotated layer lands: the rotated rectangle's axis-aligned extents. Flips only
        // relabel corners, so they leave the bounding box unchanged.
        let halfWidth = layerWidth / 2, halfHeight = layerHeight / 2
        let extentX = halfWidth * abs(cos) + halfHeight * abs(sin)
        let extentY = halfWidth * abs(sin) + halfHeight * abs(cos)
        let left = max(0, Int(floor(center.x - extentX - 0.5)))
        let right = min(target.width - 1, Int(ceil(center.x + extentX - 0.5)))
        let top = max(0, Int(floor(center.y - extentY - 0.5)))
        let bottom = min(target.height - 1, Int(ceil(center.y + extentY - 0.5)))
        guard left <= right, top <= bottom else { return }

        let bilinear = transform.sampling != .nearest
        let sourceWidth = pixels.width, sourceHeight = pixels.height

        for py in top...bottom {
            let dy = Double(py) + 0.5 - center.y
            for px in left...right {
                // The destination pixel's center, mapped back into the layer: undo the rotation,
                // then the flips, then read off the position inside the unrotated rectangle. The
                // rotation is clockwise here, and `LayerTransform.contains` walks the same inverse.
                let dx = Double(px) + 0.5 - center.x
                let unflippedX = dx * cos + dy * sin
                let unflippedY = -dx * sin + dy * cos
                let localX = transform.flipX ? -unflippedX : unflippedX
                let localY = transform.flipY ? -unflippedY : unflippedY
                let unitX = localX / layerWidth + 0.5, unitY = localY / layerHeight + 0.5
                guard unitX >= 0, unitX < 1, unitY >= 0, unitY < 1 else { continue }

                // Sample the source at the layer position. Bilinear taps past the image's edges are
                // transparent, so the boundary fades as it does when Core Graphics antialiases one.
                let sampleX = unitX * Double(sourceWidth) - 0.5
                let sampleY = unitY * Double(sourceHeight) - 0.5
                var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
                if bilinear {
                    let column = Int(sampleX.rounded(.down)), row = Int(sampleY.rounded(.down))
                    let fractionX = sampleX - Double(column), fractionY = sampleY - Double(row)
                    for tapY in 0...1 {
                        let weightY = tapY == 0 ? 1 - fractionY : fractionY
                        guard weightY > 0 else { continue }
                        let sourceRow = row + tapY
                        guard sourceRow >= 0, sourceRow < sourceHeight else { continue }
                        for tapX in 0...1 {
                            let weightX = tapX == 0 ? 1 - fractionX : fractionX
                            guard weightX > 0 else { continue }
                            let sourceColumn = column + tapX
                            guard sourceColumn >= 0, sourceColumn < sourceWidth else { continue }
                            let weight = weightX * weightY
                            let base = pixels.index(x: sourceColumn, y: sourceRow)
                            red += weight * Double(pixels.data[base])
                            green += weight * Double(pixels.data[base + 1])
                            blue += weight * Double(pixels.data[base + 2])
                            alpha += weight * Double(pixels.data[base + 3])
                        }
                    }
                } else {
                    let sourceColumn = min(sourceWidth - 1, max(0, Int((sampleX + 0.5).rounded(.down))))
                    let sourceRow = min(sourceHeight - 1, max(0, Int((sampleY + 0.5).rounded(.down))))
                    let base = pixels.index(x: sourceColumn, y: sourceRow)
                    red = Double(pixels.data[base]); green = Double(pixels.data[base + 1])
                    blue = Double(pixels.data[base + 2]); alpha = Double(pixels.data[base + 3])
                }
                guard alpha > 0 else { continue }

                // The mask covers the layer's rectangle at its own resolution; its alpha is how much
                // of the source it leaves through.
                var coverage = opacity
                if let mask, mask.width > 0, mask.height > 0 {
                    let maskX = unitX * Double(mask.width) - 0.5
                    let maskY = unitY * Double(mask.height) - 0.5
                    coverage *= Self.maskAlpha(mask, x: maskX, y: maskY)
                }
                let sourceAlpha = alpha / 255 * coverage
                guard sourceAlpha > 0 else { continue }

                let destination = target.index(x: px, y: py)
                if blendMode == .normal {
                    // Source-over on premultiplied values: the sampled color scaled by the extra
                    // coverage, plus whatever that leaves of the backdrop. No divisions needed.
                    let keep = 1 - sourceAlpha
                    target.data[destination] = Self.byte(red * coverage + keep * Double(target.data[destination]))
                    target.data[destination + 1] = Self.byte(green * coverage + keep * Double(target.data[destination + 1]))
                    target.data[destination + 2] = Self.byte(blue * coverage + keep * Double(target.data[destination + 2]))
                    target.data[destination + 3] = Self.byte(alpha * coverage + keep * Double(target.data[destination + 3]))
                } else {
                    // The blend modes work on straight colors; `composite` hands back the premultiplied
                    // result, ready to store.
                    let backdropAlpha = Double(target.data[destination + 3]) / 255
                    let sourceColor: BlendMath.Color = alpha > 0
                        ? (red / alpha, green / alpha, blue / alpha) : (0, 0, 0)
                    let backdropColor: BlendMath.Color = backdropAlpha > 0
                        ? (Double(target.data[destination]) / (backdropAlpha * 255),
                           Double(target.data[destination + 1]) / (backdropAlpha * 255),
                           Double(target.data[destination + 2]) / (backdropAlpha * 255))
                        : (0, 0, 0)
                    let result = BlendMath.composite(mode: blendMode,
                                                     backdrop: (backdropColor, backdropAlpha),
                                                     source: (sourceColor, sourceAlpha))
                    target.data[destination] = Self.byte(result.color.red * 255)
                    target.data[destination + 1] = Self.byte(result.color.green * 255)
                    target.data[destination + 2] = Self.byte(result.color.blue * 255)
                    target.data[destination + 3] = Self.byte(result.alpha * 255)
                }
            }
        }
    }

    mutating func finish() -> PixelBuffer {
        if let target { return target }
        return PixelBuffer(width: 0, height: 0)
    }

    /// The mask's alpha at a sample position, bilinearly, with taps past the edges transparent.
    private static func maskAlpha(_ mask: PixelBuffer, x: Double, y: Double) -> Double {
        let column = Int(x.rounded(.down)), row = Int(y.rounded(.down))
        let fractionX = x - Double(column), fractionY = y - Double(row)
        var alpha = 0.0
        for tapY in 0...1 {
            let weightY = tapY == 0 ? 1 - fractionY : fractionY
            guard weightY > 0 else { continue }
            let sourceRow = row + tapY
            guard sourceRow >= 0, sourceRow < mask.height else { continue }
            for tapX in 0...1 {
                let weightX = tapX == 0 ? 1 - fractionX : fractionX
                guard weightX > 0 else { continue }
                let sourceColumn = column + tapX
                guard sourceColumn >= 0, sourceColumn < mask.width else { continue }
                alpha += weightX * weightY * Double(mask.data[mask.index(x: sourceColumn, y: sourceRow) + 3])
            }
        }
        return alpha / 255
    }

    /// Rounds a 0...255 channel into a byte, clamping the blend math's float overshoot.
    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, value.rounded())))
    }
}
