import Foundation
#if canImport(PNG)
import PNG

// PNG encoding and decoding for the portable pipeline, on top of swift-png (pure Swift, no
// Apple frameworks). PixelBuffers are premultiplied RGBA8; PNG pixels are straight alpha, so
// both directions convert through RGBA<UInt8>'s premultiplied/straightened forms. Masks are
// 8-bit grayscale PNGs: white reveals, and the buffer stores coverage in its alpha as
// premultiplied white.

nonisolated enum PNGCodec {
    nonisolated enum CodecError: LocalizedError {
        case invalid, tooLarge

        var errorDescription: String? {
            switch self {
            case .invalid: "The PNG image is damaged or uses a format Compositor cannot read."
            case .tooLarge: "The PNG image exceeds the supported canvas size."
            }
        }
    }

    /// A private in-memory bytestream for swift-png, which reads and writes plain arrays.
    private struct Source: PNG.BytestreamSource {
        private var bytes: [UInt8]
        private var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func read(count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }
    }

    private struct Destination: PNG.BytestreamDestination {
        var bytes: [UInt8] = []

        mutating func write(_ buffer: [UInt8]) -> Void? {
            bytes.append(contentsOf: buffer)
            return ()
        }
    }

    /// Decodes any PNG (grayscale, palette, 16-bit, interlaced — swift-png normalizes it all)
    /// into a premultiplied RGBA8 buffer.
    static func decode(_ data: Data) throws -> PixelBuffer {
        var source = Source([UInt8](data))
        let image = try PNG.Image.decompress(stream: &source)
        let (width, height) = (image.size.x, image.size.y)
        guard width >= 1, height >= 1, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
              width * height <= DocumentLimits.maxSurfacePixels else { throw CodecError.tooLarge }
        let pixels = image.unpack(as: PNG.RGBA<UInt8>.self)
        var buffer = PixelBuffer(width: width, height: height)
        for (index, pixel) in pixels.enumerated() {
            let premultiplied = pixel.premultiplied
            let base = index * 4
            buffer.data[base] = premultiplied.r
            buffer.data[base + 1] = premultiplied.g
            buffer.data[base + 2] = premultiplied.b
            buffer.data[base + 3] = premultiplied.a
        }
        return buffer
    }

    /// Decodes a mask: any image works, its luminance becomes the coverage (white reveals).
    /// The result is premultiplied white — red, green, blue and alpha all carry the coverage.
    static func decodeMask(_ data: Data) throws -> PixelBuffer {
        var source = Source([UInt8](data))
        let image = try PNG.Image.decompress(stream: &source)
        let (width, height) = (image.size.x, image.size.y)
        guard width >= 1, height >= 1, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
              width * height <= DocumentLimits.maxSurfacePixels else { throw CodecError.tooLarge }
        let pixels = image.unpack(as: PNG.RGBA<UInt8>.self)
        var buffer = PixelBuffer(width: width, height: height)
        for (index, pixel) in pixels.enumerated() {
            let straight = pixel.straightened
            let luminance = UInt8(max(0, min(255, (0.2126 * Double(straight.r)
                + 0.7152 * Double(straight.g) + 0.0722 * Double(straight.b)).rounded())))
            let base = index * 4
            buffer.data[base] = luminance
            buffer.data[base + 1] = luminance
            buffer.data[base + 2] = luminance
            buffer.data[base + 3] = luminance
        }
        return buffer
    }

    /// Encodes a premultiplied RGBA8 buffer as an 8-bit RGBA PNG.
    static func encode(_ buffer: PixelBuffer) throws -> Data {
        var pixels: [PNG.RGBA<UInt8>] = []
        pixels.reserveCapacity(buffer.width * buffer.height)
        for base in stride(from: 0, to: buffer.data.count, by: 4) {
            pixels.append(PNG.RGBA(buffer.data[base], buffer.data[base + 1],
                                   buffer.data[base + 2], buffer.data[base + 3]).straightened)
        }
        let image = PNG.Image(packing: pixels, size: (x: buffer.width, y: buffer.height),
                              layout: .init(format: .rgba8(palette: [], fill: nil, key: nil)))
        var destination = Destination()
        try image.compress(stream: &destination, level: 9)
        return Data(destination.bytes)
    }

    /// Encodes a mask's coverage (its alpha channel) as an 8-bit grayscale PNG.
    static func encodeMask(_ buffer: PixelBuffer) throws -> Data {
        let pixels: [UInt8] = stride(from: 3, to: buffer.data.count, by: 4).map { buffer.data[$0] }
        let image = PNG.Image(packing: pixels, size: (x: buffer.width, y: buffer.height),
                              layout: .init(format: .v8(fill: nil, key: nil)))
        var destination = Destination()
        try image.compress(stream: &destination, level: 9)
        return Data(destination.bytes)
    }
}
#endif
