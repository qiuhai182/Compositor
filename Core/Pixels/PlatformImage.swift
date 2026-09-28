import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The bridge between the pixel work and whatever shows it: on Apple platforms a `CGImage`,
/// elsewhere the `PixelBuffer` itself. Software renderers build a PixelBuffer and hand it here;
/// macOS turns it into the CGImage the rest of the app already draws.
nonisolated struct PlatformImage: @unchecked Sendable {
    #if canImport(CoreGraphics)
    let cgImage: CGImage

    init(cgImage: CGImage) { self.cgImage = cgImage }

    /// Wraps `pixels` as a CGImage, sRGB like every surface the app draws. Nil only for a
    /// degenerate buffer, which no caller produces.
    init?(pixels: PixelBuffer) {
        var pixels = pixels
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let image = pixels.data.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(data: bytes.baseAddress, width: pixels.width, height: pixels.height,
                                          bitsPerComponent: 8, bytesPerRow: pixels.bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }
        guard let image else { return nil }
        self.cgImage = image
    }

    /// The image decoded to premultiplied RGBA8 pixels, first row first, as `PixelBuffer` stores them.
    var pixels: PixelBuffer {
        var buffer = PixelBuffer(width: cgImage.width, height: cgImage.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        buffer.data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: buffer.width, height: buffer.height,
                                          bitsPerComponent: 8, bytesPerRow: buffer.bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // A context counts rows from the bottom, the buffer from the top: flip the drawing so
            // the buffer's first row is the image's top row, the same flip the app's raster contexts use.
            context.translateBy(x: 0, y: CGFloat(buffer.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(buffer.width), height: CGFloat(buffer.height)))
        }
        return buffer
    }
    #else
    let pixels: PixelBuffer

    init(pixels: PixelBuffer) { self.pixels = pixels }
    #endif
}
