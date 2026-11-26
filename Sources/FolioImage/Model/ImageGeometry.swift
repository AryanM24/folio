import CoreGraphics
import Foundation

/// Where every source pixel lands after flips, quarter turns, straightening, crop and
/// resize, as affine transforms.
///
/// All transforms here use top-left-origin, y-down pixel coordinates, the way people
/// and SwiftUI think about images. ``ciTransform(scale:)`` converts to Core Image's
/// bottom-left origin. Because everything is affine, the same math maps a click on
/// screen back to a source pixel (markup) and the source forward to the output (render).
nonisolated struct ImageGeometry: Equatable, Sendable {
    /// Oriented pixel size of the original.
    let sourceSize: CGSize
    let recipe: EditRecipe

    init(sourceSize: CGSize, recipe: EditRecipe) {
        self.sourceSize = sourceSize
        var r = recipe
        r.normalize()
        self.recipe = r
    }

    /// Size after flips and quarter turns (straightening keeps the canvas size).
    var canvasSize: CGSize {
        recipe.quarterTurns % 2 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
    }

    /// Straighten angle in radians, positive is clockwise on screen.
    var straightenRadians: Double { recipe.straighten * .pi / 180 }

    /// How much a straightened image is enlarged so it still covers the whole canvas.
    var straightenScale: Double { Self.coverScale(size: canvasSize, radians: straightenRadians) }

    /// Source → canvas: flips, quarter turns, then straighten about the center.
    var canvasTransform: CGAffineTransform {
        let w = sourceSize.width, h = sourceSize.height
        var t = CGAffineTransform(
            a: recipe.flipHorizontal ? -1 : 1, b: 0, c: 0, d: recipe.flipVertical ? -1 : 1,
            tx: recipe.flipHorizontal ? w : 0, ty: recipe.flipVertical ? h : 0
        )
        var current = sourceSize
        for _ in 0..<recipe.quarterTurns {
            // 90° clockwise in y-down space: (x, y) → (H − y, x).
            t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: current.height, ty: 0))
            current = CGSize(width: current.height, height: current.width)
        }
        let angle = straightenRadians
        if angle != 0 {
            let s = straightenScale
            let cx = current.width / 2, cy = current.height / 2
            t = t.concatenating(CGAffineTransform(translationX: -cx, y: -cy))
                .concatenating(CGAffineTransform(a: cos(angle) * s, b: sin(angle) * s, c: -sin(angle) * s, d: cos(angle) * s, tx: 0, ty: 0))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
        }
        return t
    }

    /// The crop in canvas pixels, snapped to whole pixels.
    var cropRect: CGRect {
        let c = canvasSize
        let r = recipe.crop
        let x = (r.minX * c.width).rounded(), y = (r.minY * c.height).rounded()
        let maxX = (r.maxX * c.width).rounded(), maxY = (r.maxY * c.height).rounded()
        return CGRect(x: x, y: y, width: max(1, maxX - x), height: max(1, maxY - y))
    }

    /// Size after cropping, before resize.
    var croppedSize: CGSize { cropRect.size }

    /// Size of the saved image.
    var outputSize: CGSize { recipe.resize?.cgSize ?? croppedSize }

    /// Resize factors applied after cropping.
    var resizeScale: CGSize {
        CGSize(width: outputSize.width / croppedSize.width, height: outputSize.height / croppedSize.height)
    }

    /// Source → cropped image (before resize).
    var croppedTransform: CGAffineTransform {
        canvasTransform.concatenating(CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
    }

    /// Source → final output pixels.
    var outputTransform: CGAffineTransform {
        croppedTransform.concatenating(CGAffineTransform(scaleX: resizeScale.width, y: resizeScale.height))
    }

    /// Source → canvas for an image that is the original scaled by `scale`, in Core
    /// Image (y-up) coordinates. With `cropped`, also crops (output still unresized).
    func ciTransform(scale: Double, cropped: Bool) -> CGAffineTransform {
        let t = cropped ? croppedTransform : canvasTransform
        let outHeight = (cropped ? croppedSize.height : canvasSize.height) * scale
        let inHeight = sourceSize.height * scale
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: inHeight)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outHeight)
        return
            flipIn
            .concatenating(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .concatenating(t)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(flipOut)
    }

    /// Smallest scale at which a `size` rectangle rotated by `radians` still covers the
    /// unrotated rectangle, so straightening never shows empty corners.
    static func coverScale(size: CGSize, radians: Double) -> Double {
        guard size.width > 0, size.height > 0 else { return 1 }
        let c = abs(cos(radians)), s = abs(sin(radians))
        return max((size.width * c + size.height * s) / size.width, (size.width * s + size.height * c) / size.height)
    }
}
