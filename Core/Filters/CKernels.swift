import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The filter pipeline's C kernels (Core/Filters/C), called on `PixelBuffer` bytes. They are the
/// same portable C the app has always run; these wrappers only bridge the container, turning the
/// pixels-per-row stride and the kernel's bottom-up frame into the buffer's top-down coordinates.
nonisolated enum PixelKernels {
    /// Add Noise (NoisePixels.h): `amount` is Photoshop's percentage, `gaussian` picks the
    /// speckled distribution, `monochromatic` changes brightness only, and `seed` fixes the
    /// pattern. The origins offset the field so a piece of an image gets the grain that part of
    /// the whole would have.
    static func addNoise(to buffer: inout PixelBuffer, amount: Double, gaussian: Bool,
                         monochromatic: Bool, seed: UInt32, originX: Int = 0, originY: Int = 0) {
        buffer.data.withUnsafeMutableBufferPointer { pixels in
            // size_t is Int on macOS and Linux but UInt on Windows, so the sizes go through
            // numericCast and take whichever the import produced.
            noise_add_at(pixels.baseAddress, numericCast(from: buffer.width), numericCast(from: buffer.height),
                         numericCast(from: buffer.bytesPerRow),
                         Float(amount), gaussian ? 1 : 0, monochromatic ? 1 : 0, seed,
                         Int64(originX), Int64(originY))
        }
    }

    /// Colored Vignette (AdjustPixels.h): blends toward `color` with Camera Raw's falloff, framed
    /// on `frame` in the buffer's own pixel coordinates, y down (the kernel counts rows from the
    /// bottom, hence the flip). With `fillsClear` it paints transparent pixels too; without, it
    /// recolors only the pixels that are there.
    static func applyVignette(to buffer: inout PixelBuffer, frame: CGRect?, fillsClear: Bool,
                              amount: Double, midpoint: Double, roundness: Double, feather: Double,
                              highlights: Double, color: AdjustmentColor) {
        let rect = frame ?? CGRect(x: 0, y: 0, width: CGFloat(buffer.width), height: CGFloat(buffer.height))
        buffer.data.withUnsafeMutableBufferPointer { pixels in
            adjust_colored_vignette(pixels.baseAddress, numericCast(from: buffer.width), numericCast(from: buffer.height),
                                    numericCast(from: buffer.bytesPerRow),
                                    Double(rect.minX), Double(buffer.height) - Double(rect.maxY),
                                    Double(rect.width), Double(rect.height), fillsClear ? 1 : 0,
                                    amount, midpoint, roundness, feather, highlights,
                                    color.red, color.green, color.blue)
        }
    }

    /// Tonal Contrast (AdjustPixels.h): local luminance contrast with independent gains.
    /// `blurred` must be the same image blurred at the filter's detail radius —
    /// `GaussianBlur.apply` makes it.
    static func applyTonalContrast(to buffer: inout PixelBuffer, blurred: PixelBuffer,
                                   amount: Double, shadows: Double, midtones: Double, highlights: Double) {
        buffer.data.withUnsafeMutableBufferPointer { pixels in
            blurred.data.withUnsafeBufferPointer { base in
                adjust_tonal_contrast(pixels.baseAddress, base.baseAddress,
                                      numericCast(from: buffer.width), numericCast(from: buffer.height),
                                      numericCast(from: buffer.bytesPerRow), numericCast(from: blurred.bytesPerRow),
                                      amount, shadows, midtones, highlights)
            }
        }
    }

    /// Lens Correction's Remove Distortion (LensPixels.h): `k` above zero straightens barrel
    /// distortion, below zero pincushion; 0 copies the source. See `FilterParameters.lensStrength`
    /// for how the slider maps here.
    static func lensDistort(from source: PixelBuffer, k: Double) -> PixelBuffer {
        var result = PixelBuffer(width: source.width, height: source.height)
        source.data.withUnsafeBufferPointer { from in
            result.data.withUnsafeMutableBufferPointer { into in
                lens_distort(from.baseAddress, into.baseAddress,
                             numericCast(from: source.width), numericCast(from: source.height),
                             numericCast(from: source.bytesPerRow), k)
            }
        }
        return result
    }
}
