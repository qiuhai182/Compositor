import Foundation

/// The color vocabulary every project shares: painting, text, shapes and effects all store their
/// colors as these 0–1 sRGB components, so a `.comp` means the same colors wherever it is opened.
/// Turning them into a platform color is the app's job.
nonisolated struct PaletteColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    static let black = PaletteColor(red: 0, green: 0, blue: 0)
    static let white = PaletteColor(red: 1, green: 1, blue: 1)
    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red; self.green = green; self.blue = blue
    }
}
