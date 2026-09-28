import Foundation

nonisolated extension PixelBuffer {
    /// A box-average shrink to at most `maxWidth` pixels wide, or `self` when already that
    /// narrow. Averaging premultiplied pixels keeps the colors premultiplied, so previews of
    /// transparent artwork stay correct.
    func downscaled(maxWidth: Int) -> PixelBuffer {
        guard maxWidth >= 1, width > maxWidth else { return self }
        let scale = Double(width) / Double(maxWidth)
        let newHeight = max(1, Int((Double(height) / scale).rounded(.down)))
        var result = PixelBuffer(width: maxWidth, height: newHeight)
        for row in 0..<newHeight {
            let top = Int((Double(row) * scale).rounded(.down))
            let bottom = min(height, max(top + 1, Int((Double(row + 1) * scale).rounded(.down))))
            for column in 0..<maxWidth {
                let left = Int((Double(column) * scale).rounded(.down))
                let right = min(width, max(left + 1, Int((Double(column + 1) * scale).rounded(.down))))
                var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0, count = 0.0
                for y in top..<bottom {
                    var base = index(x: left, y: y)
                    for _ in left..<right {
                        red += Double(data[base]); green += Double(data[base + 1])
                        blue += Double(data[base + 2]); alpha += Double(data[base + 3])
                        count += 1; base += 4
                    }
                }
                let destination = result.index(x: column, y: row)
                result.data[destination] = UInt8((red / count).rounded())
                result.data[destination + 1] = UInt8((green / count).rounded())
                result.data[destination + 2] = UInt8((blue / count).rounded())
                result.data[destination + 3] = UInt8((alpha / count).rounded())
            }
        }
        return result
    }
}
