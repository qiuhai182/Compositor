import AppKit

// CurvePoint and CurvesSettings' stored settings live in Core; rendering a curve into pixels
// stays here.

extension CurvesSettings {
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let ctx = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: ctx)
        let table = (1...3).flatMap { channel in (0...255).map { Float(value(value(Double($0), channel: channel), channel: 0)/255) } }
        levels_apply(ctx.data!.assumingMemoryBound(to: UInt8.self), image.width*image.height, table)
        guard let result = ctx.makeImage() else { throw ExportError.render }
        return result
    }
}
