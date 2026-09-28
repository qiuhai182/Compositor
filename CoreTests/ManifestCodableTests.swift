import Foundation
import Testing
@testable import CompositorCore

/// The .comp manifest's Codable surface: what a save writes, what an older save may leave out,
/// the validity rules the loader trusts, and the pixel container the images become.
struct ManifestCodableTests {
    private static let manifestJSON = """
    {
      "format" : "com.compositor.project",
      "version" : 11,
      "colorSpace" : "sRGB",
      "resolution" : 144,
      "documentID" : "2E4B8C6F-1111-4222-8333-C44455556666",
      "width" : 64,
      "height" : 32,
      "activeLayerID" : "2E4B8C6F-AAAA-4222-8333-C44455556666",
      "guides" : [
        { "id" : "2E4B8C6F-BBBB-4222-8333-C44455556666", "axis" : "vertical", "position" : 12.5 }
      ],
      "layers" : [
        { "id" : "2E4B8C6F-CCCC-4222-8333-C44455556666", "name" : "Text 1", "isVisible" : true,
          "transform" : { "origin" : { "x" : 0, "y" : 0 }, "size" : { "width" : 64, "height" : 32 },
                          "rotation" : 0, "flipX" : false, "flipY" : false, "sampling" : "High quality" },
          "imageFile" : "images/1.png", "parentID" : null, "isGroup" : false, "opacity" : 0.5,
          "blendMode" : "Multiply", "maskFile" : null, "maskEnabled" : true, "maskSourceID" : null,
          "maskPlacement" : null, "maskLinked" : true,
          "shape" : { "kind" : "Rectangle", "red" : 1, "green" : 0, "blue" : 0, "cornerRadius" : 4 },
          "effects" : { "stroke" : { "size" : 4, "red" : 0, "green" : 0, "blue" : 0, "opacity" : 1, "inside" : true } },
          "text" : { "content" : "Hello", "fontName" : "Helvetica", "fontSize" : 24,
                     "red" : 0, "green" : 0, "blue" : 0, "alignment" : "Left", "tracking" : 0, "leading" : 0 } }
      ]
    }
    """

    @Test func manifestRoundTripsThroughJSONWithEveryOptionalField() throws {
        let layerID = UUID(), parentID = UUID(), maskID = UUID(), documentID = UUID(), activeID = UUID()
        var adjustment = LayerAdjustment(kind: .gradientMap)
        adjustment.gradientMap = GradientMapSettings(shadows: AdjustmentColor(red: 0, green: 0, blue: 0),
                                                     highlights: AdjustmentColor(red: 1, green: 1, blue: 1))
        adjustment.hsvSettings = HueSaturationSettings(hue: 10, saturation: -20, lightness: 5)
        adjustment.blurRadius = 8
        adjustment.resolvedNoiseSeed = 7
        var layer = ProjectLayerRecord(id: layerID, name: "Layer 1", isVisible: true,
                                       transform: LayerTransform(origin: .zero, size: CGSize(width: 64, height: 32)),
                                       imageFile: "images/1.png")
        layer.parentID = parentID
        layer.isGroup = false
        layer.opacity = 0.75
        layer.blendMode = .multiply
        layer.maskFile = "images/1-mask.png"
        layer.maskEnabled = true
        layer.maskSourceID = maskID
        layer.adjustment = adjustment
        layer.maskPlacement = LayerTransform(origin: CGPoint(x: 1, y: 2), size: CGSize(width: 64, height: 32))
        layer.maskLinked = false
        layer.shape = LayerShapeStyle(kind: .rectangle, red: 0, green: 0, blue: 0, cornerRadius: 6)
        layer.effects = LayerEffects(stroke: StrokeEffect(), shadow: ShadowEffect(), colorOverlay: ColorOverlayEffect(),
                                     innerShadow: InnerShadowEffect(), outerGlow: OuterGlowEffect(), innerGlow: InnerGlowEffect())
        layer.text = LayerTextStyle()
        var manifest = ProjectManifest(documentID: documentID, width: 64, height: 32, activeLayerID: activeID, layers: [layer])
        manifest.resolution = 300
        manifest.guides = [CanvasGuide(id: parentID, axis: .horizontal, position: 16)]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(manifest)
        let decoded = try JSONDecoder().decode(ProjectManifest.self, from: data)
        #expect(decoded.format == "com.compositor.project" && decoded.version == ProjectManifest.current)
        #expect(decoded.colorSpace == "sRGB" && decoded.resolution == 300)
        #expect(decoded.documentID == documentID && decoded.width == 64 && decoded.height == 32)
        #expect(decoded.activeLayerID == activeID && decoded.guides == manifest.guides)
        let record = try #require(decoded.layers.first)
        #expect(record.id == layerID && record.name == "Layer 1" && record.isVisible)
        #expect(record.transform == layer.transform && record.imageFile == "images/1.png")
        #expect(record.parentID == parentID && record.isGroup == false)
        #expect(record.blendMode == .multiply && record.opacity == 0.75)
        #expect(record.maskFile == "images/1-mask.png" && record.maskEnabled == true && record.maskSourceID == maskID)
        #expect(record.adjustment == adjustment && record.maskPlacement == layer.maskPlacement && record.maskLinked == false)
        #expect(record.shape == layer.shape && record.effects == layer.effects && record.text == layer.text)
        // Re-encoding what was decoded is byte-identical, so a load → save cycle loses nothing.
        #expect(try encoder.encode(decoded) == data)
    }

    @Test func decodesTheGoldenManifestWithAllItsOptionalFields() throws {
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(Self.manifestJSON.utf8))
        #expect(manifest.version == 11 && manifest.colorSpace == "sRGB" && manifest.resolution == 144)
        #expect(manifest.guides?.count == 1 && manifest.guides?.first?.axis == .vertical)
        let record = try #require(manifest.layers.first)
        #expect(record.isGroup == false && record.blendMode == .multiply && record.opacity == 0.5)
        #expect(record.maskEnabled == true && record.maskLinked == true)
        #expect(record.shape?.kind == .rectangle && record.shape?.cornerRadius == 4 && record.shape?.color == .white)
        #expect(record.effects?.stroke?.inside == true && record.effects?.stroke?.isEnabled == true)
        #expect(record.text?.content == "Hello" && record.text?.alignment == .left && record.text?.isValid == true)
        // Fields older projects never had stay nil, exactly as their absence means.
        #expect(record.adjustment == nil && record.maskPlacement == nil && record.maskFile == nil)
    }

    @Test func decodesAnOlderManifestWithoutLaterFields() throws {
        let json = """
        {
          "format" : "com.compositor.project",
          "version" : 8,
          "colorSpace" : "sRGB",
          "documentID" : "2E4B8C6F-1111-4222-8333-C44455556666",
          "width" : 100,
          "height" : 50,
          "layers" : [
            { "id" : "2E4B8C6F-CCCC-4222-8333-C44455556666", "name" : "Layer 1", "isVisible" : true,
              "transform" : { "origin" : { "x" : 0, "y" : 0 }, "size" : { "width" : 100, "height" : 50 },
                              "rotation" : 0, "flipX" : false, "flipY" : false, "sampling" : "High quality" },
              "imageFile" : "images/1.png" }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(json.utf8))
        #expect(manifest.version == 8 && manifest.supported.contains(8))
        #expect(manifest.guides == nil && manifest.resolution == nil && manifest.activeLayerID == nil)
        let record = try #require(manifest.layers.first)
        #expect(record.transform.size == CGSize(width: 100, height: 50))
        #expect(record.parentID == nil && record.blendMode == nil && record.effects == nil && record.text == nil)
    }

    @Test func styleEffectsAndAdjustmentValidateTheirSettings() {
        #expect(LayerTextStyle().isValid)
        var brokenStyle = LayerTextStyle()
        brokenStyle.fontSize = .nan
        #expect(!brokenStyle.isValid)

        #expect(LayerEffects().isEmpty && LayerEffects().isValid)
        var brokenEffects = LayerEffects()
        brokenEffects.stroke = StrokeEffect()
        brokenEffects.stroke?.size = StrokeEffect.maxSize + 1
        #expect(!brokenEffects.isValid)

        #expect(LayerAdjustment(kind: .hsv).isValid)
        var brokenAdjustment = LayerAdjustment(kind: .gaussianBlur)
        brokenAdjustment.blurRadius = 0
        #expect(!brokenAdjustment.isValid)
        // The resolved accessors fall back to their defaults, and isValid accepts them.
        #expect(LayerAdjustment(kind: .hsv).resolvedHSV.hue == 0)
        #expect(LayerAdjustment(kind: .motionBlur).resolvedMotionDistance == 10)
    }

    @Test func pixelBufferReadsAndWritesItsPixels() {
        var buffer = PixelBuffer(width: 3, height: 2)
        #expect(buffer.bytesPerRow == 12 && buffer.data.count == 24 && buffer.data.allSatisfy { $0 == 0 })
        buffer.fill(red: 10, green: 20, blue: 30, alpha: 255)
        buffer[x: 2, y: 1] = (200, 100, 50, 255)
        #expect(buffer[x: 2, y: 1] == (200, 100, 50, 255))
        #expect(buffer.index(x: 2, y: 1) == buffer.bytesPerRow + 8)
        let corner = buffer.subregion(x: 1, y: 1, width: 5, height: 5)
        #expect(corner.width == 2 && corner.height == 1 && corner.bytesPerRow == 8)
        #expect(corner[x: 0, y: 0] == (10, 20, 30, 255))
        #expect(corner[x: 1, y: 0] == (200, 100, 50, 255))
    }

    @Test func platformImageBridgesPixelsRoundTrip() throws {
        var buffer = PixelBuffer(width: 2, height: 1)
        buffer.fill(red: 255, green: 0, blue: 0, alpha: 255)
        buffer[x: 1, y: 0] = (0, 0, 255, 255)
        #if canImport(CoreGraphics)
        let image = try #require(PlatformImage(pixels: buffer))
        #expect(image.cgImage.width == 2 && image.cgImage.height == 1)
        // Premultiplied sRGB bytes come back in the order they went in, first row first.
        let decoded = image.pixels
        #expect(decoded.width == 2 && decoded.height == 1)
        #expect(decoded[x: 0, y: 0] == (255, 0, 0, 255))
        #expect(decoded[x: 1, y: 0] == (0, 0, 255, 255))
        #else
        #expect(PlatformImage(pixels: buffer).pixels[x: 1, y: 0] == (0, 0, 255, 255))
        #endif
    }
}
