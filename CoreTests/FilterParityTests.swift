import Testing
import Foundation
@testable import CompositorCore
#if canImport(CoreGraphics) && canImport(CoreImage)
import CoreGraphics
import CoreImage

/// The pure filter implementations against the Core Image filters they replace, rendered through
/// the same sRGB pipeline the app's filter menu uses. The tolerances are provisional — generous
/// bounds recorded on first measurement; tighten them on macOS once the real per-filter deltas are
/// known, per docs/cross-platform.md. Motion Blur's even streak against Core Image's tapered one is
/// a documented difference, not a defect, so its bounds stay loose by design.
struct FilterParityTests {
    /// Core Image works in a linear working space by default; the app's filter menu renders in
    /// sRGB, and so does the pure pipeline, so the reference renders there too.
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    private func pixelBuffer(_ image: CGImage) -> PixelBuffer {
        PlatformImage(cgImage: image).pixels
    }

    private func renderCoreImage(_ image: CIImage, width: Int, height: Int) -> PixelBuffer? {
        let extent = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        guard let rendered = Self.context.createCGImage(image, from: extent) else { return nil }
        return pixelBuffer(rendered)
    }

    /// A smooth opaque gradient, so resampling and ringing differences stay small and the
    /// comparison really is about the blur's profile.
    private func gradient(width: Int = 48, height: Int = 48) -> PixelBuffer {
        var buffer = PixelBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let p = buffer.index(x: x, y: y)
                buffer.data[p] = UInt8((Double(x) / Double(width - 1) * 255).rounded())
                buffer.data[p + 1] = UInt8((Double(y) / Double(height - 1) * 255).rounded())
                buffer.data[p + 2] = UInt8((Double(x + y) / Double(2 * (width - 1)) * 255).rounded())
                buffer.data[p + 3] = 255
            }
        }
        return buffer
    }

    /// The gradient plus a white square, so the streak and glow comparisons have a hard edge.
    private func scene(width: Int = 48, height: Int = 48) -> PixelBuffer {
        var buffer = gradient(width: width, height: height)
        for y in 16..<28 {
            for x in 16..<28 {
                buffer[x: x, y: y] = (255, 255, 255, 255)
            }
        }
        return buffer
    }

    /// Mean and share-of-pixels bounds between the pure result and the reference, over RGB.
    private func assertClose(_ pure: PixelBuffer, _ reference: PixelBuffer,
                             meanLimit: Double, pixelLimit: Int, share: Double,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(pure.width == reference.width && pure.height == reference.height)
        guard pure.width == reference.width, pure.height == reference.height else { return }
        var total = 0.0, close = 0.0, count = 0.0
        for p in stride(from: 0, to: min(pure.data.count, reference.data.count), by: 4) {
            for c in 0..<3 {
                let difference = abs(Int(pure.data[p + c]) - Int(reference.data[p + c]))
                total += Double(difference)
                if difference <= pixelLimit { close += 1 }
                count += 1
            }
        }
        guard count > 0 else { return }
        let mean = total / count
        // Record the actual numbers in the failure output, so tightening the bounds on macOS is
        // just reading them off.
        #expect(mean <= meanLimit, "mean difference \(mean) (limit \(meanLimit))")
        let shareClose = close / count
        #expect(shareClose >= share, "\(shareClose) of pixels within \(pixelLimit) (wanted \(share))")
    }

    @Test func gaussianBlurTracksCoreImage() throws {
        let input = gradient()
        let reference = try #require(renderCoreImage(
            CIImage(cgImage: PlatformImage(pixels: input)!.cgImage).applyingGaussianBlur(sigma: 3),
            width: input.width, height: input.height))
        assertClose(GaussianBlur.apply(3, to: input), reference, meanLimit: 4, pixelLimit: 12, share: 0.95)
    }

    @Test func motionBlurStaysWithinItsDocumentedDifference() throws {
        let input = scene()
        // The app's pipeline hands Core Image the radius that matches an even streak's spread.
        let reference = try #require(renderCoreImage(
            CIImage(cgImage: PlatformImage(pixels: input)!.cgImage).applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: 10.0 / 12.0.squareRoot(),
                kCIInputAngleKey: 0.0,
            ]),
            width: input.width, height: input.height))
        assertClose(MotionBlur.apply(angleDegrees: 0, distance: 10, to: input), reference,
                    meanLimit: 12, pixelLimit: 40, share: 0.85)
    }

    @Test func portableDispatchAgreesWithDirectCalls() throws {
        // The same comparison, through the dispatch the headless pipeline will use.
        let input = gradient()
        let reference = try #require(renderCoreImage(
            CIImage(cgImage: PlatformImage(pixels: input)!.cgImage).applyingGaussianBlur(sigma: 2),
            width: input.width, height: input.height))
        var parameters = FilterParameters()
        parameters.radius = 2
        assertClose(PortableFilter.gaussianBlur.render(parameters, scale: 1, to: input), reference,
                    meanLimit: 4, pixelLimit: 12, share: 0.95)
    }
}
#endif
