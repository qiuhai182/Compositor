import Foundation

nonisolated enum LayerBlendMode: String, Codable, CaseIterable, Sendable {
    case normal = "Normal"
    case darken = "Darken", multiply = "Multiply", colorBurn = "Color Burn"
    case linearBurn = "Linear Burn"
    case lighten = "Lighten", screen = "Screen", colorDodge = "Color Dodge"
    case linearDodge = "Linear Dodge (Add)"
    case overlay = "Overlay", softLight = "Soft Light", hardLight = "Hard Light"
    case vividLight = "Vivid Light", linearLight = "Linear Light", pinLight = "Pin Light", hardMix = "Hard Mix"
    case difference = "Difference", exclusion = "Exclusion", subtract = "Subtract", divide = "Divide"
    case hue = "Hue", saturation = "Saturation", color = "Color", luminosity = "Luminosity"

    /// Photoshop's grouping: darkening modes together, then lightening, then contrast, then the
    /// comparative ones, then the component modes. The menu draws a line between each group.
    static let groups: [[LayerBlendMode]] = [
        [.normal],
        [.darken, .multiply, .colorBurn, .linearBurn],
        [.lighten, .screen, .colorDodge, .linearDodge],
        [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix],
        [.difference, .exclusion, .subtract, .divide],
        [.hue, .saturation, .color, .luminosity]
    ]

    // Photoshop's Darker Color and Lighter Color are left out: they compare a pixel's whole
    // brightness rather than working a channel at a time, and neither framework implements them.
}
