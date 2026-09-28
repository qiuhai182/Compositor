import Testing
import Foundation
@testable import CompositorCore

/// The portable PNG codec: round-trips through premultiplied RGBA8, masks through grayscale,
/// on every platform.
struct PNGCodecTests {
    private func solid(_ color: PixelBuffer.Color, width: Int = 8, height: Int = 8) -> PixelBuffer {
        var buffer = PixelBuffer(width: width, height: height)
        buffer.fill(color)
        return buffer
    }

    /// Opaque pixels must survive a round-trip exactly: straightening and re-premultiplying an
    /// opaque color is the identity.
    @Test func opaqueRoundTripIsExact() throws {
        let original = solid(PixelBuffer.Color(red: 200, green: 90, blue: 30, alpha: 255), width: 5, height: 3)
        let decoded = try PNGCodec.decode(PNGCodec.encode(original))
        #expect(decoded == original)
    }

    /// Premultiplied colors round-trip within a small rounding band: straightening then
    /// re-premultiplying a 8-bit color can drift by at most one step per channel.
    @Test func translucentRoundTripStaysWithinRounding() throws {
        var original = PixelBuffer(width: 16, height: 16)
        for index in 0..<16 {
            let alpha = UInt8(index * 16 + 15)
            original[x: index, y: 0] = (UInt8(Double(220) * Double(alpha) / 255),
                                  UInt8(Double(120) * Double(alpha) / 255),
                                  UInt8(Double(40) * Double(alpha) / 255), alpha)
        }
        let decoded = try PNGCodec.decode(PNGCodec.encode(original))
        #expect(decoded.width == original.width && decoded.height == original.height)
        for index in 0..<16 {
            let source = original[x: index, y: 0], result = decoded[x: index, y: 0]
            #expect(abs(Int(source.red) - Int(result.red)) <= 1)
            #expect(abs(Int(source.green) - Int(result.green)) <= 1)
            #expect(abs(Int(source.blue) - Int(result.blue)) <= 1)
            #expect(abs(Int(source.alpha) - Int(result.alpha)) <= 1)
        }
    }

    /// A mask's coverage survives as 8-bit grayscale, whatever the channel it started in.
    @Test func maskRoundTripKeepsCoverage() throws {
        var mask = PixelBuffer(width: 4, height: 4)
        mask[x: 0, y: 0] = (0, 0, 0, 0)
        mask[x: 1, y: 0] = (255, 255, 255, 255)
        mask[x: 2, y: 0] = (128, 128, 128, 128)
        let decoded = try PNGCodec.decodeMask(PNGCodec.encodeMask(mask))
        #expect(decoded[x: 0, y: 0].alpha == 0)
        #expect(decoded[x: 1, y: 0].alpha == 255)
        #expect(abs(Int(decoded[x: 2, y: 0].alpha) - 128) <= 1)
    }

    /// Encoding a subregion encodes exactly that region's pixels.
    @Test func subregionEncodesItsOwnPixels() throws {
        var original = PixelBuffer(width: 10, height: 10)
        original.fill(PixelBuffer.Color(red: 10, green: 200, blue: 60, alpha: 255))
        original[x: 0, y: 0] = (255, 255, 255, 255)
        let region = original.subregion(x: 2, y: 3, width: 4, height: 5)
        let decoded = try PNGCodec.decode(PNGCodec.encode(region))
        #expect(decoded.width == 4 && decoded.height == 5)
        #expect(decoded[x: 0, y: 0] == (255, 255, 255, 255))
        #expect(decoded[x: 3, y: 4] == (10, 200, 60, 255))
    }

    /// Garbage input is rejected, not crashed into.
    @Test func decodeRejectsGarbage() {
        #expect(throws: (any Error).self) { try PNGCodec.decode(Data([1, 2, 3])) }
    }
}
