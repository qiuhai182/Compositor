import Foundation

/// One compositing backend's drawing surface: the software renderer uses it everywhere, and the
/// macOS app adapts Core Graphics to it (see Compositor/Rendering/CGRenderer.swift). A renderer is
/// begun with a canvas size and background, draws any number of layers bottom-up, and hands back
/// the finished pixels. Coordinates are document pixels, y down: the transform's center places the
/// layer's (unrotated) `size`, its rotation is clockwise, and the first pixel row is the top row.
///
/// The mask is a coverage overlay in the layer's own space: its alpha channel encodes opacity, and
/// it maps onto the layer's rectangle by its own width and height, independent of the source
/// image's size — so a mask can be coarser or finer than the pixels it covers.
nonisolated protocol Renderer {
    /// Starts a fresh canvas `width`×`height`, filled with the premultiplied `background`.
    mutating func begin(width: Int, height: Int, background: PixelBuffer.Color)
    /// Composites one layer's `pixels` onto the canvas through `transform`, `blendMode` and
    /// `opacity`, with the optional layer-space coverage `mask`.
    mutating func draw(_ pixels: PixelBuffer, transform: LayerTransform,
                       blendMode: LayerBlendMode, opacity: Double, mask: PixelBuffer?)
    /// Ends the render and returns the composited pixels. Drawing after `finish` needs a new `begin`.
    mutating func finish() -> PixelBuffer
}
