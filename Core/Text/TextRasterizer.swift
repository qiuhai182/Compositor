import Foundation

/// Lays out and rasterizes a `LayerTextStyle` into a `PixelBuffer` with no platform text
/// framework: advances, kerning, tracking and leading here, glyph coverage from stb_truetype via
/// `FontBook`. The layout is the horizontal Latin subset — no shaping, no bidirectional text, no
/// vertical layout — the portable renderer's documented downgrade from the macOS Type tool
/// (docs/cross-platform.md).
nonisolated struct TextRasterizer {
    nonisolated struct Glyph {
        /// Where the letter sits in the whole content, as the UTF-16 offset `LayerTextStyle`
        /// addresses runs by.
        let utf16Index: Int
        let font: FontBook.LoadedFont
        let glyphIndex: Int
        /// The pen's x when the letter draws, from the layout's left edge.
        let x: Double
    }

    nonisolated struct Line {
        var glyphs: [Glyph] = []
        var width: Double = 0
    }

    nonisolated struct Layout {
        var lines: [Line] = []
        var width: Int = 0
        var height: Int = 0
        /// The first line's baseline, from the top of the layout box; the rest follow one
        /// `LayerTextStyle.lineHeight` apart.
        var firstBaseline: Double = 0
    }

    /// Breaks the text into lines and measures them, or nil when no font can be loaded at all.
    static func layout(_ style: LayerTextStyle, fonts: FontBook) -> Layout? {
        guard let base = fonts.font(named: style.fontName) else { return nil }
        let scale = base.scale(forPixelHeight: Double(style.fontSize))
        let metrics = base.metrics(scale: scale)
        let lineHeight = Double(style.lineHeight)
        let tracking = Double(style.tracking)

        var layout = Layout()
        var utf16Base = 0
        // Each "\n" starts a new line; per-letter runs are looked up by UTF-16 offset into the
        // whole content, so the breaks count toward it too.
        for paragraph in style.content.components(separatedBy: "\n") {
            var line = Line()
            var pen = 0.0
            var previous: (font: FontBook.LoadedFont, glyph: Int)? = nil
            var utf16Index = utf16Base
            for scalar in paragraph.unicodeScalars {
                defer { utf16Index += scalar.utf16.count }
                let font = fonts.font(named: style.fontName(at: utf16Index)) ?? base
                let glyphIndex = font.glyphIndex(of: scalar)
                if !line.glyphs.isEmpty { pen += tracking }
                // Kerning only pairs glyphs of one face; a run change just moves the pen on.
                if let previous = previous, previous.font === font {
                    pen += font.kernAdvance(left: previous.glyph, right: glyphIndex, scale: scale)
                }
                line.glyphs.append(Glyph(utf16Index: utf16Index, font: font, glyphIndex: glyphIndex, x: pen))
                pen += font.advance(of: glyphIndex, scale: scale)
                line.width = pen
                previous = (font, glyphIndex)
            }
            utf16Base += paragraph.utf16.count + 1
            layout.lines.append(line)
        }
        layout.width = max(1, Int(ceil(layout.lines.map(\.width).max() ?? 0)))
        layout.height = max(1, Int(ceil(metrics.ascent + Double(layout.lines.count - 1) * lineHeight + metrics.descent)))
        layout.firstBaseline = metrics.ascent
        return layout
    }

    /// The text as premultiplied RGBA pixels, colored by the style and its runs, or nil when no
    /// font can be loaded. The buffer hugs the text: as wide as the widest line and as tall as
    /// the first ascent, the last descent, and the leading between.
    static func render(_ style: LayerTextStyle, fonts: FontBook) -> PixelBuffer? {
        guard let layout = layout(style, fonts: fonts) else { return nil }
        var buffer = PixelBuffer(width: layout.width, height: layout.height)
        let lineHeight = Double(style.lineHeight)
        for (lineIndex, line) in layout.lines.enumerated() {
            let baseline = layout.firstBaseline + Double(lineIndex) * lineHeight
            let xOrigin: Double = switch style.alignment {
            case .left: 0
            case .center: (Double(layout.width) - line.width) / 2
            case .right: Double(layout.width) - line.width
            }
            for glyph in line.glyphs {
                let scale = glyph.font.scale(forPixelHeight: Double(style.fontSize))
                guard let coverage = glyph.font.coverage(of: glyph.glyphIndex, scale: scale) else { continue }
                let color = style.color(at: glyph.utf16Index)
                let red = Int(Double((color.red * 255).rounded()))
                let green = Int(Double((color.green * 255).rounded()))
                let blue = Int(Double((color.blue * 255).rounded()))
                let left = Int((xOrigin + glyph.x).rounded()) + coverage.xOffset
                let top = Int(baseline.rounded()) + coverage.yOffset
                // Source-over of the premultiplied glyph color × coverage over what's there.
                for row in 0..<coverage.height {
                    let y = top + row
                    guard y >= 0 && y < buffer.height else { continue }
                    for column in 0..<coverage.width {
                        let x = left + column
                        guard x >= 0 && x < buffer.width else { continue }
                        let ink = Int(coverage.data[row * coverage.width + column])
                        guard ink > 0 else { continue }
                        let keep = 255 - ink
                        let pixel = buffer[x: x, y: y]
                        buffer[x: x, y: y] = (
                            UInt8(min(255, red * ink / 255 + Int(pixel.red) * keep / 255)),
                            UInt8(min(255, green * ink / 255 + Int(pixel.green) * keep / 255)),
                            UInt8(min(255, blue * ink / 255 + Int(pixel.blue) * keep / 255)),
                            UInt8(min(255, ink + Int(pixel.alpha) * keep / 255)))
                    }
                }
            }
        }
        return buffer
    }
}
