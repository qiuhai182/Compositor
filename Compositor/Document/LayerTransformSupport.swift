import Foundation
import CoreGraphics

// The parts of the transform model that reach into app-side rendering helpers (`BrushRaster`)
// or the floating-selection machinery. Everything purely geometric lives in Core/LayerTransform.swift,
// which the cross-platform core package also compiles (see docs/cross-platform.md).

extension LayerTransform {
    var unitToDocument: CGAffineTransform { BrushRaster.pixelToDocument(self, width: 1, height: 1) }
    /// A transform placing the unit square as `map` does — a rotated, maybe flipped rectangle (shear, which only
    /// uneven scaling of something rotated adds, is dropped). Keeps this transform's sampling.
    func placing(_ map: CGAffineTransform) -> LayerTransform {
        // Kept horizontal flip and the rotation nearest this one's, so the numbers stay familiar.
        let sign: CGFloat = flipX ? -1 : 1
        let angle = atan2(map.b * sign, map.a * sign)
        let along = -map.c * sin(angle) + map.d * cos(angle)
        let middle = CGPoint(x: 0.5, y: 0.5).applying(map)
        var result = self
        result.size = CGSize(width: hypot(map.a, map.b), height: abs(along))
        let degrees = angle * 180 / .pi
        result.rotation = degrees + ((rotation - degrees) / 360).rounded() * 360
        result.flipY = along < 0
        result.origin = CGPoint(x: middle.x - result.size.width / 2, y: middle.y - result.size.height / 2)
        return result
    }
    /// This placement carried along as a layer moves from `old` to `new`.
    func following(from old: LayerTransform, to new: LayerTransform) -> LayerTransform {
        guard old != new else { return self }
        // A plain move carries exactly.
        if old.size == new.size, old.rotation == new.rotation, old.flipX == new.flipX, old.flipY == new.flipY {
            var moved = self
            moved.origin.x += new.origin.x - old.origin.x
            moved.origin.y += new.origin.y - old.origin.y
            return moved
        }
        return placing(unitToDocument.concatenating(old.unitToDocument.inverted()).concatenating(new.unitToDocument))
    }
}

/// Several layers transformed together: the upright box around them when the edit began (what the draft edits),
/// and each one's transform then.
struct TransformGroup {
    let box: LayerTransform
    let originals: [UUID: LayerTransform]
}

struct TransformEdit {
    let layerID: UUID
    var draft: LayerTransform
    let persistent: Bool
    /// Set when transforming selected pixels (Cmd-T with a selection) rather than a layer.
    var floating: FloatingTransform? = nil
    /// Set once a handle is Cmd-dragged: the four corners (document pixels, handle order) move
    /// freely, and Apply resamples the pixels into that shape.
    var corners: [CGPoint]? = nil
    /// Set when an unlinked mask is selected: the edit places the mask alone (its `placement`).
    var mask = false
    /// Set when several layers are selected: the draft is the box around them all, and each follows it.
    var group: TransformGroup? = nil
}

struct TransformDrag {
    enum Mode { case move, resize(Int), rotate, distort(Int) }
    let original: LayerTransform
    let start: CGPoint
    let mode: Mode
    /// The distortion's corners when the drag began; nil for an ordinary transform.
    var originalCorners: [CGPoint]? = nil

    /// Corners after dragging to `point`: a corner handle moves its corner, an edge handle both of
    /// that edge's corners, and the body the whole shape. Nil when the drag isn't distorting.
    func corners(to point: CGPoint, shift: Bool = false) -> [CGPoint]? {
        guard var result = originalCorners else { return nil }
        var dx = point.x - start.x, dy = point.y - start.y
        // Shift keeps what's being dragged on one axis.
        if shift {
            if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
        }
        let moved: [Int]
        switch mode {
        case .distort(let index): moved = index.isMultiple(of: 2) ? [index / 2] : [index / 2, (index / 2 + 1) % 4]
        case .move: moved = [0, 1, 2, 3]
        default: return nil
        }
        for corner in moved { result[corner].x += dx; result[corner].y += dy }
        return result
    }

    func updated(to point: CGPoint, lockRatio: Bool, shift: Bool, option: Bool = false) -> LayerTransform {
        var result = original
        switch mode {
        case .distort: break
        case .move:
            var dx = point.x - start.x, dy = point.y - start.y
            if shift {
                if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
            }
            result.origin.x += dx
            result.origin.y += dy
        case .rotate:
            let center = original.center
            let delta = atan2(point.y - center.y, point.x - center.x)
                - atan2(start.y - center.y, start.x - center.x)
            result.rotation += delta * 180 / .pi
            if shift { result.rotation = (result.rotation / 15).rounded() * 15 }
        case .resize(let index):
            let handle = LayerTransform.handles[index]
            let anchorUnit = option ? CGPoint(x: 0.5, y: 0.5) : CGPoint(x: 1 - handle.x, y: 1 - handle.y)
            let anchor = original.point(anchorUnit)
            // Use the initial handle plus pointer delta to avoid a jump on grab.
            let initialHandle = original.point(handle)
            let dx = initialHandle.x + point.x - start.x - anchor.x
            let dy = initialHandle.y + point.y - start.y - anchor.y
            // Center-to-handle distances cover half the size on each axis.
            let span: CGFloat = option ? 2 : 1
            let localX = (dx * cos(original.radians) + dy * sin(original.radians)) * span
            let localY = (-dx * sin(original.radians) + dy * cos(original.radians)) * span
            let sx = handle.x * 2 - 1, sy = handle.y * 2 - 1
            // Dragging a handle past the opposite side turns the layer over rather than stopping at nothing:
            // the size stays positive and the layer is flipped on that axis, as a negative scale would.
            let rawWidth = sx == 0 ? original.size.width : localX * sx
            let rawHeight = sy == 0 ? original.size.height : localY * sy
            let mirroredX = rawWidth < 0, mirroredY = rawHeight < 0
            var width = max(1, abs(rawWidth))
            var height = max(1, abs(rawHeight))
            if lockRatio != shift {
                let factor: CGFloat
                if sx == 0 { factor = height / original.size.height }
                else if sy == 0 { factor = width / original.size.width }
                else {
                    // Project onto the original diagonal for proportional scaling.
                    factor = max(1 / min(original.size.width, original.size.height),
                        (localX * sx * original.size.width + localY * sy * original.size.height)
                        / (original.size.width * original.size.width + original.size.height * original.size.height))
                }
                width = original.size.width * factor
                height = original.size.height * factor
            }
            result.size = CGSize(width: width, height: height)
            if mirroredX { result.flipX.toggle() }
            if mirroredY { result.flipY.toggle() }
            // Turned over, the box lies on the other side of the anchor.
            let offsetX = (0.5 - anchorUnit.x) * width * (mirroredX ? -1 : 1)
            let offsetY = (0.5 - anchorUnit.y) * height * (mirroredY ? -1 : 1)
            let center = CGPoint(x: anchor.x + offsetX * cos(original.radians) - offsetY * sin(original.radians),
                                 y: anchor.y + offsetX * sin(original.radians) + offsetY * cos(original.radians))
            result.origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        }
        return result.isValid ? result : original
    }
}

/// Moving a layer snaps its edges and center to the canvas and to the other layers. The pull is a fixed distance
/// on screen, so it feels the same at any zoom, and small enough to slide past without a fight.
nonisolated enum TransformSnap {
    /// How close, in screen points, a guide comes before it snaps.
    static let distance: CGFloat = 10

    /// `box` moved so that whichever of its left, center or right lands nearest an `xs` target does, and the same
    /// vertically — each axis on its own, and only within `tolerance` document pixels. The targets it landed on
    /// come back too, to draw a line along.
    static func offset(for box: CGRect, xs: [CGFloat], ys: [CGFloat],
                       tolerance: CGFloat) -> (offset: CGSize, x: CGFloat?, y: CGFloat?) {
        let horizontal = shift([box.minX, box.midX, box.maxX], to: xs, tolerance: tolerance)
        let vertical = shift([box.minY, box.midY, box.maxY], to: ys, tolerance: tolerance)
        return (CGSize(width: horizontal.move, height: vertical.move), horizontal.target, vertical.target)
    }
    /// The smallest move that puts one of `guides` on one of `targets`, and the target it met.
    private static func shift(_ guides: [CGFloat], to targets: [CGFloat],
                              tolerance: CGFloat) -> (move: CGFloat, target: CGFloat?) {
        var best: (move: CGFloat, target: CGFloat)?
        for guideValue in guides {
            for target in targets {
                let move = target - guideValue
                guard abs(move) <= tolerance else { continue }
                if let current = best, abs(current.move) <= abs(move) { continue }
                best = (move, target)
            }
        }
        return (best?.move ?? 0, best?.target)
    }
}
