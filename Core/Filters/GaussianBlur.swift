import Foundation

/// A Gaussian blur for premultiplied RGBA pixels: three box-blur passes whose widths come from the
/// classic boxes-for-Gauss construction, each swept horizontally and then vertically. This is the
/// stand-in for Core Image's `CIGaussianBlur` off macOS; three boxes track a Gaussian closely, so
/// the two agree to within a few levels except in a hard edge's first ring (see
/// docs/cross-platform.md for the measured tolerances).
nonisolated enum GaussianBlur {
    /// Blurs every channel, alpha included, by `sigma` pixels. Below half a level the image passes
    /// through unchanged.
    static func apply(_ sigma: Double, to input: PixelBuffer) -> PixelBuffer {
        guard sigma >= 0.5, input.width >= 1, input.height >= 1 else { return input }
        var current = input
        for radius in boxRadii(for: sigma) where radius > 0 {
            var blurred = PixelBuffer(width: current.width, height: current.height)
            blurred.data = sweep(current.data, lineCount: current.height, lineStride: current.bytesPerRow,
                                 count: current.width, elementStride: 4, radius: radius)
            blurred.data = sweep(blurred.data, lineCount: current.width, lineStride: 4,
                                 count: current.height, elementStride: current.bytesPerRow, radius: radius)
            current = blurred
        }
        return current
    }

    /// The three box half-widths whose boxes best approximate a Gaussian of `sigma`. Odd widths
    /// `narrow` and `narrow + 2`, roughly `narrowShare` of them narrow.
    static func boxRadii(for sigma: Double) -> [Int] {
        let passes = 3.0
        let idealWidth = (12 * sigma * sigma / passes + 1).squareRoot()
        var narrow = Int(idealWidth)
        if narrow % 2 == 0 { narrow -= 1 }
        narrow = max(1, narrow)
        let wide = narrow + 2
        let narrowShare = (12 * sigma * sigma - passes * Double(narrow * narrow)
            - 4 * passes * Double(narrow) - 3 * passes) / (-4 * Double(narrow) - 4)
        let narrowCount = min(Int(passes), max(0, Int(narrowShare.rounded())))
        return [Int](repeating: (narrow - 1) / 2, count: narrowCount)
            + [Int](repeating: (wide - 1) / 2, count: Int(passes) - narrowCount)
    }

    /// One box sweep: a sliding-window average along every line, the edges clamped so the window
    /// shrinks at the borders rather than reading past the image. The lines run along
    /// `elementStride` bytes, one every `lineStride`, which makes the same loop serve both axes:
    /// horizontal lines are the rows (element stride 4), vertical lines the columns (element
    /// stride one row). Reads `source` untouched, writes a copy.
    private static func sweep(_ source: [UInt8], lineCount: Int, lineStride: Int,
                              count: Int, elementStride: Int, radius: Int) -> [UInt8] {
        var result = source
        let window = 2 * radius + 1
        var acc = [UInt32](repeating: 0, count: 4)
        for line in 0..<lineCount {
            let base = line * lineStride
            for c in 0..<4 { acc[c] = 0 }
            for offset in -radius...radius {
                let x = min(count - 1, max(0, offset))
                let p = base + x * elementStride
                for c in 0..<4 { acc[c] += UInt32(source[p + c]) }
            }
            for x in 0..<count {
                let p = base + x * elementStride
                for c in 0..<4 {
                    result[p + c] = UInt8((acc[c] + UInt32(window / 2)) / UInt32(window))
                }
                guard count > 1 else { continue }
                let leaving = min(count - 1, max(0, x - radius))
                let entering = min(count - 1, max(0, x + radius + 1))
                for c in 0..<4 {
                    acc[c] += UInt32(source[base + entering * elementStride + c])
                    acc[c] -= UInt32(source[base + leaving * elementStride + c])
                }
            }
        }
        return result
    }
}
