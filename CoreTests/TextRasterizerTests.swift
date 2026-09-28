import Testing
import Foundation
@testable import CompositorCore

/// The portable text rasterizer: a style and a system font become readable ink on every platform.
/// Whatever face the runner has is fine — the assertions are about shape and layout, not a
/// particular font. Machines with no loadable system font skip.
struct TextRasterizerTests {
    private func book() throws -> FontBook {
        let fonts = FontBook()
        guard fonts.font(named: "Helvetica") != nil else { throw Skip("No loadable system font on this machine") }
        return fonts
    }

    private func style(_ content: String, size: Double = 48,
                       alignment: TextAlignment = .left) -> LayerTextStyle {
        var style = LayerTextStyle()
        style.content = content
        style.fontSize = size
        style.alignment = alignment
        return style
    }

    /// The columns with ink in the rows of one line of a rendered layout.
    private func inkedColumns(_ buffer: PixelBuffer, rows: Range<Int>) -> Range<Int>? {
        var first: Int? = nil, last: Int? = nil
        for y in rows where y >= 0 && y < buffer.height {
            for x in 0..<buffer.width where buffer[x: x, y: y].alpha > 0 {
                first = min(first ?? x, x)
                last = max(last ?? x, x + 1)
            }
        }
        guard let first, let last else { return nil }
        return first..<last
    }

    @Test func renderTurnsTextIntoInkInsideTheCanvas() throws {
        let buffer = try TextRasterizer.render(style("Ag"), fonts: book())
        #expect(buffer != nil)
        guard let buffer else { return }
        // A 48-point word pair is wider than tall but not by much, and both dimensions are real.
        #expect(buffer.width >= 30 && buffer.width <= 300)
        #expect(buffer.height >= 40 && buffer.height <= 150)
        // The stems are solid somewhere, and there is plenty of ink overall.
        let alphaSum = stride(from: 3, to: buffer.data.count, by: 4).reduce(0) { $0 + Int(buffer.data[$1]) }
        #expect(alphaSum > 500)
        #expect(stride(from: 3, to: buffer.data.count, by: 4).contains { buffer.data[$0] > 200 })
    }

    @Test func blankTextDrawsNothing() throws {
        let fonts = try book()
        let blank = TextRasterizer.render(style("  "), fonts: fonts)
        #expect(blank != nil)
        guard let blank else { return }
        #expect(blank.data.allSatisfy { $0 == 0 })
    }

    @Test func renderIsDeterministic() throws {
        let fonts = try book()
        #expect(TextRasterizer.render(style("Ag"), fonts: fonts) == TextRasterizer.render(style("Ag"), fonts: fonts))
    }

    @Test func layoutScalesWithTheFontSize() throws {
        let fonts = try book()
        let half = TextRasterizer.layout(style("Ag", size: 24), fonts: fonts)
        let full = TextRasterizer.layout(style("Ag", size: 48), fonts: fonts)
        #expect(half != nil && full != nil)
        guard let half, let full else { return }
        // Advances are font units times scale, so doubling the size doubles the width, modulo
        // integer rounding.
        #expect(Double(full.width) > Double(half.width) * 1.7)
        #expect(Double(full.width) < Double(half.width) * 2.3)
    }

    @Test func twoLinesAreOneLeadingApart() throws {
        let fonts = try book()
        var style = self.style("Ag\nAg")
        style.leading = 60
        let layout = TextRasterizer.layout(style, fonts: fonts)
        #expect(layout != nil)
        guard let layout, layout.lines.count == 2 else { return }
        // The box is the first ascent, the second descent, and one leading between.
        #expect(Double(layout.height) >= layout.firstBaseline + 60 + 5)
        #expect(Double(layout.height) <= layout.firstBaseline + 60 + 30)
    }

    @Test func alignmentMovesShortLinesWithinTheBox() throws {
        let fonts = try book()
        // A wide line above a narrow one: alignment can only move the narrow one.
        var left = style("WM\ni")
        left.alignment = .left
        var right = style("WM\ni")
        right.alignment = .right
        let leftLayout = TextRasterizer.layout(left, fonts: fonts)
        let rightLayout = TextRasterizer.layout(right, fonts: fonts)
        #expect(leftLayout != nil && rightLayout != nil)
        guard let leftLayout, let rightLayout, leftLayout.width == rightLayout.width,
              let leftBuffer = TextRasterizer.render(left, fonts: fonts),
              let rightBuffer = TextRasterizer.render(right, fonts: fonts) else { return }
        // Rows around the second baseline carry the "i": its stem is x-height above the
        // baseline, and the first line's descenders end well above this window.
        let secondBaseline = leftLayout.firstBaseline + Double(left.lineHeight)
        let rows = Int((secondBaseline - 30).rounded())..<Int((secondBaseline + 3).rounded())
        guard let leftInk = inkedColumns(leftBuffer, rows: rows),
              let rightInk = inkedColumns(rightBuffer, rows: rows) else {
            Issue.record("The second line drew no ink")
            return
        }
        #expect(leftInk.lowerBound < leftBuffer.width / 2)
        #expect(rightInk.lowerBound > leftBuffer.width / 2)
    }

    @Test func colorRunsColorTheLettersTheyCover() throws {
        let fonts = try book()
        var style = self.style("Ag")
        style.colorRuns = [LayerTextColorRun(location: 1, length: 1, red: 1, green: 0, blue: 0)]
        guard let buffer = TextRasterizer.render(style, fonts: fonts) else {
            Issue.record("No render")
            return
        }
        // Both letters drew, and the red one left pixels that are redder than they are green or blue.
        let alphaSum = stride(from: 3, to: buffer.data.count, by: 4).reduce(0) { $0 + Int(buffer.data[$1]) }
        #expect(alphaSum > 500)
        #expect(stride(from: 0, to: buffer.data.count, by: 4).contains { x in
            buffer.data[x] > 100 && buffer.data[x] > buffer.data[x + 1] + 50 && buffer.data[x] > buffer.data[x + 2] + 50
        })
    }
}
