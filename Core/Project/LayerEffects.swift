import Foundation

// The effects a layer draws around its pixels: stroke, shadow, overlay, glows. The settings are
// pure data and math — the geometry of where an effect lands is here, turning it into pixels
// is the app's renderer.

/// A line drawn around what the layer shows, outside its edge or inside it.
nonisolated struct StrokeEffect: Codable, Equatable, Sendable {
    /// Supported document-pixel width; preview work is bounded independently of this value.
    static let maxSize: CGFloat = 500
    var enabled: Bool? = nil // Missing in older projects means visible.
    var isEnabled: Bool { enabled ?? true }
    var size: CGFloat = 4
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var opacity: Double = 1
    var inside = false
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var isValid: Bool {
        size.isFinite && (0...StrokeEffect.maxSize).contains(size) && opacity.isFinite && (0...1).contains(opacity)
            && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// The layer's shape repeated behind it, offset and softened.
nonisolated struct ShadowEffect: Codable, Equatable, Sendable {
    var enabled: Bool? = nil
    var isEnabled: Bool { enabled ?? true }
    /// Where the light comes from, in degrees counterclockwise from the right, as Photoshop's dial is: 90 is from
    /// straight above, which drops the shadow straight down.
    var angle: CGFloat = 90
    var distance: CGFloat = 20
    var blur: CGFloat = 20
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var opacity: Double = 0.5
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    /// Where the shadow sits, in layer pixels (y grows downward, as the layer's own pixels do).
    var offset: CGSize {
        let radians = angle * .pi / 180
        // The shadow falls away from the light, and a layer's pixels count y downward.
        return CGSize(width: -cos(radians) * distance, height: sin(radians) * distance)
    }
    var isValid: Bool {
        [angle, distance, blur].allSatisfy(\.isFinite) && (-360...360).contains(angle)
            && (0...5000).contains(distance) && (0...500).contains(blur)
            && opacity.isFinite && (0...1).contains(opacity)
            && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// A flat color over everything the layer shows.
nonisolated struct ColorOverlayEffect: Codable, Equatable, Sendable {
    var enabled: Bool? = nil
    var isEnabled: Bool { enabled ?? true }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var opacity: Double = 1
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var isValid: Bool {
        opacity.isFinite && (0...1).contains(opacity) && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// A shadow cast inside the layer's own edges, as though it were cut out of what is behind it.
nonisolated struct InnerShadowEffect: Codable, Equatable, Sendable {
    var enabled: Bool? = nil
    var isEnabled: Bool { enabled ?? true }
    var angle: CGFloat = 90
    var distance: CGFloat = 10
    var blur: CGFloat = 10
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var opacity: Double = 0.5
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    /// Where the shadow falls, in layer pixels (y grows downward).
    var offset: CGSize {
        let radians = angle * .pi / 180
        return CGSize(width: -cos(radians) * distance, height: sin(radians) * distance)
    }
    var isValid: Bool {
        [angle, distance, blur].allSatisfy(\.isFinite) && (-360...360).contains(angle)
            && (0...5000).contains(distance) && (0...500).contains(blur)
            && opacity.isFinite && (0...1).contains(opacity)
            && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// A soft glow drawn omnidirectionally around the outside of what the layer shows.
nonisolated struct OuterGlowEffect: Codable, Equatable, Sendable {
    var enabled: Bool? = nil
    var isEnabled: Bool { enabled ?? true }
    var size: CGFloat = 20
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
    var opacity: Double = 0.75
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var isValid: Bool {
        size.isFinite && (0...500).contains(size)
            && opacity.isFinite && (0...1).contains(opacity)
            && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// A glow cast inside the layer's own edges, emanating inward from its boundary.
nonisolated struct InnerGlowEffect: Codable, Equatable, Sendable {
    var enabled: Bool? = nil
    var isEnabled: Bool { enabled ?? true }
    var size: CGFloat = 10
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
    var opacity: Double = 0.75
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var isValid: Bool {
        size.isFinite && (0...500).contains(size)
            && opacity.isFinite && (0...1).contains(opacity)
            && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// What a layer draws around itself. Kept with the layer, so it follows every edit and can be changed or removed
/// at any time; the pixels themselves are never touched.
nonisolated struct LayerEffects: Codable, Equatable, Sendable {
    var stroke: StrokeEffect? = nil
    var shadow: ShadowEffect? = nil
    var colorOverlay: ColorOverlayEffect? = nil
    var innerShadow: InnerShadowEffect? = nil
    var outerGlow: OuterGlowEffect? = nil
    var innerGlow: InnerGlowEffect? = nil
    var isEmpty: Bool { stroke == nil && shadow == nil && colorOverlay == nil && innerShadow == nil && outerGlow == nil && innerGlow == nil }
    var isValid: Bool {
        (stroke?.isValid ?? true) && (shadow?.isValid ?? true)
            && (colorOverlay?.isValid ?? true) && (innerShadow?.isValid ?? true)
            && (outerGlow?.isValid ?? true) && (innerGlow?.isValid ?? true)
    }
    var kinds: [LayerEffectKind] { LayerEffectKind.allCases.filter { contains($0) } }
    func contains(_ kind: LayerEffectKind) -> Bool {
        switch kind {
        case .stroke: return stroke != nil
        case .shadow: return shadow != nil
        case .colorOverlay: return colorOverlay != nil
        case .innerShadow: return innerShadow != nil
        case .outerGlow: return outerGlow != nil
        case .innerGlow: return innerGlow != nil
        }
    }
    func isEnabled(_ kind: LayerEffectKind) -> Bool {
        switch kind {
        case .stroke: return stroke?.isEnabled == true
        case .shadow: return shadow?.isEnabled == true
        case .colorOverlay: return colorOverlay?.isEnabled == true
        case .innerShadow: return innerShadow?.isEnabled == true
        case .outerGlow: return outerGlow?.isEnabled == true
        case .innerGlow: return innerGlow?.isEnabled == true
        }
    }
    /// The effect's own color, and a way to put a new one back.
    func color(_ kind: LayerEffectKind) -> PaletteColor? {
        switch kind {
        case .stroke: return stroke?.color
        case .shadow: return shadow?.color
        case .colorOverlay: return colorOverlay?.color
        case .innerShadow: return innerShadow?.color
        case .outerGlow: return outerGlow?.color
        case .innerGlow: return innerGlow?.color
        }
    }
    mutating func setColor(_ color: PaletteColor, for kind: LayerEffectKind) {
        switch kind {
        case .stroke: stroke?.red = color.red; stroke?.green = color.green; stroke?.blue = color.blue
        case .shadow: shadow?.red = color.red; shadow?.green = color.green; shadow?.blue = color.blue
        case .colorOverlay: colorOverlay?.red = color.red; colorOverlay?.green = color.green; colorOverlay?.blue = color.blue
        case .innerShadow: innerShadow?.red = color.red; innerShadow?.green = color.green; innerShadow?.blue = color.blue
        case .outerGlow: outerGlow?.red = color.red; outerGlow?.green = color.green; outerGlow?.blue = color.blue
        case .innerGlow: innerGlow?.red = color.red; innerGlow?.green = color.green; innerGlow?.blue = color.blue
        }
    }
    mutating func remove(_ kind: LayerEffectKind) {
        switch kind {
        case .stroke: stroke = nil
        case .shadow: shadow = nil
        case .colorOverlay: colorOverlay = nil
        case .innerShadow: innerShadow = nil
        case .outerGlow: outerGlow = nil
        case .innerGlow: innerGlow = nil
        }
    }
    mutating func setEnabled(_ enabled: Bool, for kind: LayerEffectKind) {
        switch kind {
        case .stroke: stroke?.enabled = enabled
        case .shadow: shadow?.enabled = enabled
        case .colorOverlay: colorOverlay?.enabled = enabled
        case .innerShadow: innerShadow?.enabled = enabled
        case .outerGlow: outerGlow?.enabled = enabled
        case .innerGlow: innerGlow?.enabled = enabled
        }
    }
    var visible: LayerEffects {
        LayerEffects(stroke: stroke?.isEnabled == true ? stroke : nil,
                     shadow: shadow?.isEnabled == true ? shadow : nil,
                     colorOverlay: colorOverlay?.isEnabled == true ? colorOverlay : nil,
                     innerShadow: innerShadow?.isEnabled == true ? innerShadow : nil,
                     outerGlow: outerGlow?.isEnabled == true ? outerGlow : nil,
                     innerGlow: innerGlow?.isEnabled == true ? innerGlow : nil)
    }
}

nonisolated enum LayerEffectKind: String, CaseIterable, Sendable {
    case stroke = "Stroke", shadow = "Drop Shadow", colorOverlay = "Color Overlay", innerShadow = "Inner Shadow", outerGlow = "Outer Glow", innerGlow = "Inner Glow"
}
