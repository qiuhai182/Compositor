import Testing
@testable import CompositorCore

/// The core package compiles on every platform; these keep its model semantics honest there too.
struct CoreTests {
    @Test func transformPlacesUnitSquareAroundItsCenter() {
        let transform = LayerTransform(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 50))
        #expect(transform.center == CGPoint(x: 60, y: 45))
        #expect(transform.point(CGPoint(x: 0, y: 0)) == CGPoint(x: 10, y: 20))
        #expect(transform.point(CGPoint(x: 1, y: 1)) == CGPoint(x: 110, y: 70))
        #expect(transform.contains(CGPoint(x: 60, y: 45)))
        #expect(!transform.contains(CGPoint(x: 200, y: 200)))
    }

    @Test func transformRoundsToWholePixelsAndDegrees() {
        let transform = LayerTransform(origin: CGPoint(x: 10.4, y: -3.6), size: CGSize(width: 99.6, height: 0.4), rotation: 12.6)
        let rounded = transform.rounded()
        #expect(rounded.origin == CGPoint(x: 10, y: -4))
        #expect(rounded.size.width == 100 && rounded.size.height == 1)
        #expect(rounded.rotation == 13)
    }

    @Test func invalidTransformsAreRejected() {
        #expect(!LayerTransform(origin: .zero, size: CGSize(width: 0, height: 10)).isValid)
        #expect(LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)).isValid)
        #expect(!LayerTransform(origin: CGPoint(x: .infinity, y: 0), size: CGSize(width: 1, height: 1)).isValid)
    }

    @Test func blendModeRawValuesMatchTheManifestSpelling() {
        // These strings are what .comp manifests store; changing one is a format change.
        #expect(LayerBlendMode(rawValue: "Linear Dodge (Add)") == .linearDodge)
        #expect(LayerBlendMode(rawValue: "Normal") == .normal)
        #expect(LayerBlendMode.groups.flatMap(\.self).count == LayerBlendMode.allCases.count)
    }

    @Test func documentLimitsStayUnderTheirSideLimit() {
        #expect(DocumentLimits.maxSurfacePixels < DocumentLimits.maxSide * DocumentLimits.maxSide)
        #expect(DocumentLimits.documentPixelBudget >= DocumentLimits.maxSurfacePixels)
    }
}
