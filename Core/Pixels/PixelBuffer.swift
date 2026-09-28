import Foundation

/// The cross-platform compositor's pixel container: RGBA8, premultiplied, alpha last, rows packed
/// back to back, first row first. Renderers and pixel math work on these bytes directly; the macOS
/// side converts to and from CGImage through `PlatformImage`.
nonisolated struct PixelBuffer: Equatable, Sendable {
    let width: Int
    let height: Int
    /// Bytes from the start of one pixel row to the next; the rows are packed, so `width * 4`.
    let bytesPerRow: Int
    var data: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.data = [UInt8](repeating: 0, count: self.bytesPerRow * height)
    }

    /// Byte offset of a pixel's first (red) component.
    func index(x: Int, y: Int) -> Int { y * bytesPerRow + x * 4 }

    /// The pixel at `x`,`y` as premultiplied RGBA bytes.
    subscript(x x: Int, y y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        get {
            let base = index(x: x, y: y)
            return (data[base], data[base + 1], data[base + 2], data[base + 3])
        }
        set {
            let base = index(x: x, y: y)
            data[base] = newValue.red; data[base + 1] = newValue.green
            data[base + 2] = newValue.blue; data[base + 3] = newValue.alpha
        }
    }

    /// A premultiplied RGBA8 color, as `fill` and the renderers' backgrounds take it.
    nonisolated struct Color: Equatable, Sendable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8

        init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }

        static let clear = Color(red: 0, green: 0, blue: 0, alpha: 0)
        static let white = Color(red: 255, green: 255, blue: 255, alpha: 255)
        static let black = Color(red: 0, green: 0, blue: 0, alpha: 255)
    }

    /// Fills every pixel with one premultiplied color.
    mutating func fill(_ color: Color) {
        fill(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// Fills every pixel with one premultiplied color.
    mutating func fill(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        for y in 0..<height {
            var base = y * bytesPerRow
            for _ in 0..<width {
                data[base] = red; data[base + 1] = green; data[base + 2] = blue; data[base + 3] = alpha
                base += 4
            }
        }
    }

    /// A tightly packed copy of the `width`×`height` pixels whose top-left sits at (`x`,`y`),
    /// clipped to the buffer's own bounds.
    func subregion(x: Int, y: Int, width: Int, height: Int) -> PixelBuffer {
        let left = max(0, x), top = max(0, y)
        let right = min(self.width, x + width), bottom = min(self.height, y + height)
        var copy = PixelBuffer(width: max(0, right - left), height: max(0, bottom - top))
        for row in 0..<copy.height {
            let source = index(x: left, y: top + row)
            copy.data.replaceSubrange(row * copy.bytesPerRow..<(row * copy.bytesPerRow + copy.width * 4),
                                      with: data[source..<(source + copy.width * 4)])
        }
        return copy
    }
}
