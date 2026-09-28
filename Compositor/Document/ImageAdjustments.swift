import AppKit

/// Draws an image into an RGBA buffer (premultiplied, alpha last), lets a C kernel change it in place,
/// and returns the result.
nonisolated enum ImageAdjustmentPixels {
    static func run(_ image: CGImage, _ body: (UnsafeMutablePointer<UInt8>, Int, Int, Int) -> Void) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        body(data.assumingMemoryBound(to: UInt8.self), image.width, image.height, context.bytesPerRow)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
    static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

// AdjustmentColor and the settings structs (Exposure through Grain) live in Core. The C kernels
// they feed are what stays here — each as the `apply` the session code calls.

extension ExposureSettings {
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let tables = Array([[Float]](repeating: table, count: 3).joined())
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, _ in
            levels_apply(pixels, width * height, tables)
        }
    }
}

extension GradientMapSettings {
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let (dark, light) = ends
        // Split into explicitly typed steps: as one expression the type checker times out (Xcode 26.1).
        func channel(_ from: Double, _ to: Double, _ t: Double) -> UInt8 {
            let value: Double = from + (to - from) * t
            let scaled: Double = (value * 255).rounded()
            return UInt8(min(255.0, max(0.0, scaled)))
        }
        var table = [UInt8]()
        table.reserveCapacity(256 * 3)
        for index in 0...255 {
            let t: Double = Double(index) / 255
            table.append(channel(dark.red, light.red, t))
            table.append(channel(dark.green, light.green, t))
            table.append(channel(dark.blue, light.blue, t))
        }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_gradient_map(pixels, width, height, stride, table)
        }
    }
}

extension BlackWhiteSettings {
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        // The C routine's order: red, yellow, green, cyan, blue, magenta.
        let weights = [reds, yellows, greens, cyans, blues, magentas].map { Float($0 / 100) }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_black_white(pixels, width, height, stride, weights,
                               tint ? 1 : 0, tintHue, tintSaturation / 100)
        }
    }
}

extension ColorBalanceSettings {
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        guard !isIdentity else { return image }
        let shadows = [shadowCyanRed, shadowMagentaGreen, shadowYellowBlue].map { Float($0 / 100) }
        let midtones = [midCyanRed, midMagentaGreen, midYellowBlue].map { Float($0 / 100) }
        let highlights = [highlightCyanRed, highlightMagentaGreen, highlightYellowBlue].map { Float($0 / 100) }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_color_balance(pixels, width, height, stride, shadows, midtones, highlights,
                                 preserveLuminosity ? 1 : 0)
        }
    }
}

extension GrainSettings {
    /// `origin` and `unitsPerPixel` place the image's pixels in document space (a whole layer at 1:1 is
    /// origin zero, one unit per pixel); `seed` replaces the stored pattern when given.
    func apply(_ image: CGImage, origin: CGPoint = .zero, unitsPerPixel: CGFloat = 1, seed: UInt32? = nil) throws -> CGImage {
        guard isValid, unitsPerPixel.isFinite, unitsPerPixel > 0 else { throw ProjectError.invalid }
        guard amount > 0 else { return image }
        let pattern = seed ?? self.seed
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_grain(pixels, width, height, stride, amount, size, roughness, pattern,
                         Double(origin.x), Double(origin.y), Double(unitsPerPixel))
        }
    }
}
