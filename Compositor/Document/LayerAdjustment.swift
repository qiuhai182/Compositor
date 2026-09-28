import AppKit
import CoreImage

// AdjustmentKind's cases and LayerAdjustment's stored settings live in Core. What references
// SF Symbols or FilterKind, and what turns the settings into pixels, stays here.

extension AdjustmentKind {
    var symbol: String {
        switch self {
        case .curves: return "point.topleft.down.to.point.bottomright.curvepath"
        case .levels: return "slider.horizontal.3"
        case .hsv: return "circle.lefthalf.filled"
        case .exposure: return "plusminus.circle"
        case .gradientMap: return "paintpalette"
        case .grain: return "circle.grid.3x3"
        case .gaussianBlur: return "drop.fill"
        case .motionBlur: return "wind"
        case .addNoise: return "circle.dotted"
        case .invert: return "circle.righthalf.filled"
        case .blackWhite: return "circle.filled.pattern.diagonalline.rectangle"
        case .colorBalance: return "scale.3d"
        }
    }
    var filterKind: FilterKind? {
        switch self {
        case .curves: return .curves
        case .blackWhite: return .blackWhite
        case .colorBalance: return .colorBalance
        case .exposure: return .exposure
        case .gradientMap: return .gradientMap
        case .grain: return .grain
        case .gaussianBlur: return .gaussianBlur
        case .motionBlur: return .motionBlur
        case .addNoise: return .addNoise
        // Hue/Saturation and Levels have panels of their own; Invert has nothing to set.
        case .hsv, .levels, .invert: return nil
        }
    }
}

extension LayerAdjustment {
    /// `region` is the part of the document `image` covers (the whole image at one unit per pixel when
    /// omitted), so Grain's pattern stays fixed in the document however the canvas splits its drawing.
    func apply(_ image: CGImage, region: CGRect? = nil, scale: CGFloat = 1) throws -> CGImage {
        switch kind {
        case .hsv:
            return try HueSaturationFilter.run(HueSaturationJob(image: image,
                settings: resolvedHSV,
                selection: nil, pixelToDocument: .identity, thumbnail: false)).image
        case .levels: return try LevelsFilter.run(LevelsJob(image: image, settings: levels, selection: nil, mapping: .identity))
        case .curves: return try curves.apply(image)
        case .blackWhite: return try blackWhite.apply(image)
        case .colorBalance: return try colorBalance.apply(image)
        case .exposure: return try exposure.apply(image)
        case .gradientMap: return try gradientMap.apply(image)
        case .grain:
            let region = region ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
            return try grain.apply(image, origin: region.origin, unitsPerPixel: region.width / CGFloat(max(1, image.width)))
        case .gaussianBlur, .motionBlur, .addNoise:
            var settings = FilterSettings()
            settings.radius = gaussianRadius
            settings.angle = resolvedMotionAngle
            settings.distance = resolvedMotionDistance
            settings.amount = resolvedNoiseAmount
            settings.gaussian = resolvedNoiseGaussian
            settings.monochromatic = resolvedNoiseMonochromatic
            let filterKind: FilterKind = switch kind {
            case .gaussianBlur: .gaussianBlur
            case .motionBlur: .motionBlur
            default: .addNoise
            }
            return try PixelFilter.run(FilterJob(kind: filterKind, image: image, settings: settings,
                                                  scale: scale, selection: nil, mapping: .identity,
                                                  seed: resolvedNoiseSeed,
                                                  noiseOrigin: region?.origin ?? .zero))
        case .invert:
            return try PixelInvert.run(PixelInvert.Job(image: image, isMask: false,
                                                       pixelToDocument: .identity, selection: nil))
        }
    }
}

extension EditorSession {
    func addAdjustment(_ kind: AdjustmentKind) {
        guard canEditLayers, let document, document.layers.count < 10_000 else { return }
        var layer = ImageLayer(name: kind.rawValue, blankSize: document.size)
        var adjustment = LayerAdjustment(kind: kind)
        // A new Gradient Map runs from the foreground to the background color, as in Photoshop;
        // each Grain layer gets a pattern of its own.
        if kind == .gradientMap {
            adjustment.gradientMap = GradientMapSettings(shadows: AdjustmentColor(foregroundColor), highlights: AdjustmentColor(backgroundColor))
        }
        if kind == .grain { adjustment.grain.seed = .random(in: .min ... .max) }
        if kind == .addNoise { adjustment.resolvedNoiseSeed = .random(in: .min ... .max) }
        layer.adjustment = adjustment
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        let index = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        beginEdit("New \(kind.rawValue) Adjustment")
        self.document?.layers.insert(layer, at: index)
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        activeLayerID = layer.id
        endEdit()
        // Invert has nothing to set, so the new layer just applies rather than opening an editor.
        if kind.isEditable { adjustmentEditingID = layer.id }
    }
    func updateAdjustment(_ id: UUID, value: LayerAdjustment) {
        guard let index = document?.layers.firstIndex(where: { $0.id == id }), value.isValid else { return }
        document?.layers[index].adjustment = value
        brushRevision += 1
    }
}
