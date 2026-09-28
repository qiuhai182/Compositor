import Foundation

/// Photoshop's Motion Blur: every destination pixel is the average of the source along the
/// `distance`-long streak through it, at `angleDegrees` counterclockwise from horizontal, the way
/// Photoshop counts. This is the stand-in for Core Image's `CIMotionBlur`, which tapers the streak
/// like a Gaussian where Photoshop (and this) smear evenly — the app picks the CI radius that
/// matches an even streak's spread, so the two agree in overall reach but differ within the streak
/// (see docs/cross-platform.md).
nonisolated enum MotionBlur {
    static func apply(angleDegrees: Double, distance: Double, to input: PixelBuffer) -> PixelBuffer {
        guard distance >= 1, input.width >= 1, input.height >= 1 else { return input }
        var result = PixelBuffer(width: input.width, height: input.height)
        let radians = angleDegrees * .pi / 180
        // Photoshop counts the angle in a y-up space; the buffer's rows run downward.
        let directionX = cos(radians)
        let directionY = -sin(radians)
        let half = distance / 2
        // Two samples per streak pixel keeps a diagonal streak smooth without full resampling.
        let steps = max(1, (distance * 2).rounded(.up))
        for y in 0..<input.height {
            for x in 0..<input.width {
                var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0, samples = 0.0
                for step in 0...Int(steps) {
                    let along = -half + distance * Double(step) / steps
                    guard let pixel = sample(input, x: Double(x) + 0.5 + directionX * along,
                                             y: Double(y) + 0.5 + directionY * along) else { continue }
                    red += pixel.red; green += pixel.green; blue += pixel.blue; alpha += pixel.alpha
                    samples += 1
                }
                guard samples > 0 else { continue }  // the whole streak was past the edge: transparent
                let p = result.index(x: x, y: y)
                result.data[p] = UInt8((red / samples).rounded())
                result.data[p + 1] = UInt8((green / samples).rounded())
                result.data[p + 2] = UInt8((blue / samples).rounded())
                result.data[p + 3] = UInt8((alpha / samples).rounded())
            }
        }
        return result
    }

    /// A bilinear sample at a fractional position, in the buffer's premultiplied bytes. Nil past
    /// the image's edge, where the streak has nothing to average; within half a pixel of the edge
    /// the sample clamps to it.
    private static func sample(_ buffer: PixelBuffer, x: Double, y: Double)
        -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard x >= -0.5, y >= -0.5, x <= Double(buffer.width) - 0.5, y <= Double(buffer.height) - 0.5 else { return nil }
        let left = max(0, min(buffer.width - 1, Int(x.rounded(.down))))
        let top = max(0, min(buffer.height - 1, Int(y.rounded(.down))))
        let right = min(buffer.width - 1, left + 1)
        let bottom = min(buffer.height - 1, top + 1)
        let across = max(0, min(1, x - Double(left)))
        let down = max(0, min(1, y - Double(top)))
        var mixed = [Double](repeating: 0, count: 4)
        for (offset, weight) in [(0, (1 - across) * (1 - down)), (1, across * (1 - down)),
                                 (2, (1 - across) * down), (3, across * down)] {
            guard weight > 0 else { continue }
            let p = buffer.index(x: offset % 2 == 0 ? left : right, y: offset < 2 ? top : bottom)
            for c in 0..<4 { mixed[c] += Double(buffer.data[p + c]) * weight }
        }
        return (mixed[0], mixed[1], mixed[2], mixed[3])
    }
}
