import Testing
import Foundation
@testable import CompositorCore

/// The portable filter pipeline: what each filter does to known pixels, on every platform. The
/// macOS-only comparison against the app's Core Image filters lives in FilterParityTests.
struct PortableFilterTests {
    private let gray = PixelBuffer.Color(red: 128, green: 128, blue: 128, alpha: 255)

    private func solid(_ color: PixelBuffer.Color, width: Int = 16, height: Int = 16) -> PixelBuffer {
        var buffer = PixelBuffer(width: width, height: height)
        buffer.fill(color)
        return buffer
    }

    /// An opaque image with a white dot at the center of a transparent field.
    private func dot(width: Int = 17, height: Int = 17, at center: (Int, Int)? = nil) -> PixelBuffer {
        var buffer = PixelBuffer(width: width, height: height)
        let (x, y) = center ?? (width / 2, height / 2)
        buffer[x: x, y: y] = (255, 255, 255, 255)
        return buffer
    }

    private func alphaSum(_ buffer: PixelBuffer) -> Int {
        stride(from: 3, to: buffer.data.count, by: 4).reduce(0) { $0 + Int(buffer.data[$1]) }
    }

    // MARK: Gaussian Blur

    @Test func gaussianBlurLeavesAUniformImageAlone() {
        let uniform = solid(gray)
        #expect(GaussianBlur.apply(3, to: uniform) == uniform)
    }

    @Test func gaussianBlurSpreadsTheDotAndConservesItsAlpha() {
        // A box blur conserves the pixel sum; three passes only add rounding, and the dot sits
        // far enough from the edges for the clamped windows to stay full width.
        let blurred = GaussianBlur.apply(2, to: dot())
        #expect(abs(alphaSum(blurred) - 255) <= 16)
        let center = blurred[x: 8, y: 8].alpha
        #expect(center > 0 && center < 255)
        // A symmetric blur of a centered dot stays symmetric.
        for offset in 1...4 {
            #expect(blurred[x: 8 + offset, y: 8].alpha == blurred[x: 8 - offset, y: 8].alpha)
            #expect(blurred[x: 8, y: 8 + offset].alpha == blurred[x: 8, y: 8 - offset].alpha)
        }
        #expect(blurred[x: 0, y: 0].alpha == 0)
    }

    @Test func gaussianBlurRadiiFollowTheBoxesForGaussConstruction() {
        #expect(GaussianBlur.boxRadii(for: 1) == [0, 1, 1])
        #expect(GaussianBlur.boxRadii(for: 5) == [4, 4, 5])
        // Small sigmas degenerate to a pass-through; large ones keep three real boxes.
        #expect(GaussianBlur.apply(0.4, to: dot()) == dot())
        #expect(GaussianBlur.boxRadii(for: 40).allSatisfy { $0 > 0 })
    }

    // MARK: Motion Blur

    @Test func motionBlurStreaksAlongTheAngle() {
        // A dot smeared horizontally reaches half the streak length on either side, and nothing
        // above or below the dot's row.
        let blurred = MotionBlur.apply(angleDegrees: 0, distance: 5, to: dot())
        #expect(blurred[x: 10, y: 8].alpha > 0)
        #expect(blurred[x: 11, y: 8].alpha == 0)
        #expect(blurred[x: 8, y: 11].alpha == 0)
        // Ninety degrees streaks up and down instead, with the same reach.
        let vertical = MotionBlur.apply(angleDegrees: 90, distance: 5, to: dot())
        #expect(vertical[x: 8, y: 10].alpha > 0)
        #expect(vertical[x: 8, y: 11].alpha == 0)
        #expect(vertical[x: 11, y: 8].alpha == 0)
    }

    @Test func motionBlurThinsPastTheEdgesInsteadOfDraggingThem() {
        // A dot near the edge loses the samples that fall outside, so its smear carries less
        // energy than one with the whole streak inside, though it still reaches the edge itself.
        let nearEdge = MotionBlur.apply(angleDegrees: 0, distance: 6, to: dot(at: (2, 8)))
        let centered = MotionBlur.apply(angleDegrees: 0, distance: 6, to: dot(at: (8, 8)))
        #expect(alphaSum(nearEdge) < alphaSum(centered))
        #expect(nearEdge[x: 0, y: 8].alpha > 0)
    }

    @Test func motionBlurKeepsShortDistancesUntouched() {
        let image = solid(gray)
        #expect(MotionBlur.apply(angleDegrees: 45, distance: 0.5, to: image) == image)
    }

    // MARK: Bloom

    @Test func bloomAddsGlowToBrightPixelsAndLeavesFarDarkOnes() {
        var image = PixelBuffer(width: 12, height: 1)
        image[x: 0, y: 0] = (255, 255, 255, 255)
        image[x: 1, y: 0] = (255, 255, 255, 255)
        image[x: 10, y: 0] = (40, 40, 40, 255)  // below the knee, and beyond the glow's reach
        let bloomed = Bloom.apply(intensity: 1, radius: 2, to: image)
        // Bright pixels only ever gain, the glow lights their neighbors, and the far dark pixel
        // is untouched.
        #expect(bloomed[x: 0, y: 0].red == 255)
        #expect(bloomed[x: 4, y: 0].red > 0)
        #expect(bloomed[x: 10, y: 0] == (40, 40, 40, 255))
        #expect(bloomed[x: 11, y: 0] == (0, 0, 0, 0))
        // Zero intensity and a sub-half-pixel radius both pass the image through.
        #expect(Bloom.apply(intensity: 0, radius: 2, to: image) == image)
        #expect(Bloom.apply(intensity: 1, radius: 0.4, to: image) == image)
    }

    @Test func bloomStaysInsideTheLayersAlpha() {
        var image = PixelBuffer(width: 3, height: 1)
        image[x: 1, y: 0] = (128, 128, 128, 128)  // half coverage: premultiplied channels at alpha/2
        let bloomed = Bloom.apply(intensity: 5, radius: 1, to: image)
        for x in 0..<3 {
            let pixel = bloomed[x: x, y: 0]
            #expect(pixel.red <= pixel.alpha && pixel.green <= pixel.alpha && pixel.blue <= pixel.alpha)
        }
    }

    // MARK: Add Noise

    @Test func addNoiseIsDeterministicPerSeedAndSparesTransparentPixels() {
        var noisy = solid(gray)
        PixelKernels.addNoise(to: &noisy, amount: 30, gaussian: false, monochromatic: true, seed: 7)
        var again = solid(gray)
        PixelKernels.addNoise(to: &again, amount: 30, gaussian: false, monochromatic: true, seed: 7)
        #expect(noisy == again)
        var other = solid(gray)
        PixelKernels.addNoise(to: &other, amount: 30, gaussian: false, monochromatic: true, seed: 8)
        #expect(noisy != other)
        // Monochromatic noise shifts every channel by the same amount; mid-gray never clamps.
        let shifted = noisy[x: 3, y: 3]
        #expect(Int(shifted.red) - 128 == Int(shifted.green) - 128)
        #expect(Int(shifted.red) - 128 == Int(shifted.blue) - 128)
        // Transparent pixels stay transparent.
        var sparse = PixelBuffer(width: 4, height: 4)
        sparse[x: 1, y: 1] = (128, 128, 128, 128)
        PixelKernels.addNoise(to: &sparse, amount: 50, gaussian: true, monochromatic: false, seed: 3)
        #expect(sparse[x: 0, y: 0] == (0, 0, 0, 0))
    }

    // MARK: Vignette

    @Test func vignetteDarkensTheCornersTowardTheColor() {
        let image = solid(PixelBuffer.Color(red: 160, green: 160, blue: 160, alpha: 255))
        var framed = image
        PixelKernels.applyVignette(to: &framed, frame: nil, fillsClear: false, amount: 80, midpoint: 50,
                                   roundness: 100, feather: 60, highlights: 0,
                                   color: AdjustmentColor(red: 0, green: 0, blue: 0))
        #expect(framed[x: 0, y: 0].red < 160 && framed[x: 15, y: 15].red < 160)
        #expect(framed[x: 7, y: 7].red == 160 || framed[x: 8, y: 8].red == 160)  // the center keeps its tone
        #expect(framed[x: 0, y: 0].alpha == 255)
        // Zero amount passes the image through.
        var untouched = image
        PixelKernels.applyVignette(to: &untouched, frame: nil, fillsClear: false, amount: 0, midpoint: 50,
                                   roundness: 100, feather: 60, highlights: 0,
                                   color: AdjustmentColor(red: 0, green: 0, blue: 0))
        #expect(untouched == image)
    }

    // MARK: Tonal Contrast

    @Test func tonalContrastWorksOnLocalDetailOnly() {
        // A white square on mid gray: the square's edges are the local detail.
        var image = solid(PixelBuffer.Color(red: 80, green: 80, blue: 80, alpha: 255))
        for y in 6..<10 {
            for x in 6..<10 { image[x: x, y: y] = (255, 255, 255, 255) }
        }
        let blurred = GaussianBlur.apply(2, to: image)
        // A uniform field has no local detail to boost.
        var uniform = solid(gray)
        let uniformBlurred = GaussianBlur.apply(2, to: uniform)  // a distinct buffer, same flat content
        PixelKernels.applyTonalContrast(to: &uniform, blurred: uniformBlurred, amount: 100,
                                        shadows: 0, midtones: 100, highlights: 0)
        #expect(uniform == solid(gray))
        // With a midtone gain the square's edges pull away from their blurred neighborhood.
        var boosted = image
        PixelKernels.applyTonalContrast(to: &boosted, blurred: blurred, amount: 100,
                                        shadows: 0, midtones: 100, highlights: 0)
        #expect(boosted != image)
        // Zero amounts are a no-op even where detail exists.
        var untouched = image
        PixelKernels.applyTonalContrast(to: &untouched, blurred: blurred, amount: 100,
                                        shadows: 0, midtones: 0, highlights: 0)
        #expect(untouched == image)
    }

    // MARK: Lens Correction

    @Test func lensDistortWithZeroStrengthCopiesTheSource() {
        let image = solid(PixelBuffer.Color(red: 20, green: 200, blue: 90, alpha: 255))
        #expect(PixelKernels.lensDistort(from: image, k: 0) == image)
    }

    @Test func lensDistortPincushionTurnsTheCornersTransparent() {
        let image = solid(gray)
        // Negative k pushes the samples outward, so the corners read past the source and go
        // transparent; the center keeps its tone.
        let straightened = PixelKernels.lensDistort(from: image, k: -0.2)
        #expect(straightened[x: 0, y: 0].alpha == 0)
        #expect(straightened[x: 8, y: 8] == (128, 128, 128, 255))
    }

    // MARK: Dispatch

    @Test func everyFilterRendersThroughTheDispatchWithoutChangingSize() {
        let image = solid(PixelBuffer.Color(red: 100, green: 140, blue: 180, alpha: 255), width: 9, height: 7)
        for filter in PortableFilter.allCases {
            let result = filter.render(FilterParameters(), scale: 1, to: image)
            #expect(result.width == 9 && result.height == 7)
        }
        // The dispatch reaches the same implementations the tests above call directly.
        #expect(PortableFilter.gaussianBlur.render(FilterParameters(radius: 2), scale: 1, to: image)
            == GaussianBlur.apply(2, to: image))
    }
}
