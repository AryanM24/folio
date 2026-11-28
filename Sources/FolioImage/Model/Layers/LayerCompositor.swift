import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Synchronization

/// Renders the layer stack over the developed base image.
///
/// For each visible layer, bottom → top: render the content (or, for adjustment and
/// retouch layers, process everything below), multiply in the mask, clip to the layer
/// below, add effects, then blend with the layer's mode and opacity (gamma-encoded, see
/// `BlendModes.swift`). Pass-through groups blend their children straight into the
/// stack; isolated groups are flattened first and then treated like one layer.
nonisolated enum LayerCompositor {
    /// `layers` (bottom → top, source pixels) composited over `base`: the developed
    /// original at `scale`, in Core Image coordinates (origin bottom-left, extent
    /// = source size × `scale`). Returns the same extent.
    static func composite(base: CIImage, layers: [Layer], assets: any AssetStore, scale: Double) -> CIImage {
        let document = Document(rect: base.extent, scale: scale, assets: assets)
        return document.stack(layers, over: base).cropped(to: base.extent)
    }

    /// The layer's visible bounds in source pixels (after its transform), for transform
    /// handles and snapping. `.null` for layers that cover the document (fills, adjustments).
    static func bounds(of layer: Layer, assets: any AssetStore) -> CGRect {
        if let quad = layer.perspective {
            let xs = [quad.topLeft.x, quad.topRight.x, quad.bottomRight.x, quad.bottomLeft.x]
            let ys = [quad.topLeft.y, quad.topRight.y, quad.bottomRight.y, quad.bottomLeft.y]
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        if case .group(let group) = layer.content {
            return group.layers.reduce(CGRect.null) { rect, child in
                var child = child
                child.transform = child.transform.concatenating(layer.transform)
                return rect.union(bounds(of: child, assets: assets))
            }
        }
        let local = contentBounds(layer.content, assets: assets)
        return local.isNull ? .null : local.applying(layer.transform)
    }

    /// Bounds of `content` in layer space, or `.null` when it covers the document.
    static func contentBounds(_ content: Layer.Content, assets: any AssetStore) -> CGRect {
        switch content {
        case .pixels(let id):
            guard let image = decoded(id, assets: assets) else { return .null }
            return CGRect(origin: .zero, size: image.extent.size)
        case .text(let text): return TextRenderer.bounds(of: text)
        case .shape(let shape): return ShapeRenderer.bounds(of: shape)
        case .paint(let paint): return PaintRenderer.bounds(of: paint, assets: assets)
        case .fill, .adjustment, .retouch, .group: return .null
        }
    }

    // MARK: Drawing helpers shared by the renderers

    /// A transparent bitmap covering `bounds` (layer space, y down) at `scale`, drawn by
    /// `draw` in layer coordinates, returned in the layer-space-at-scale convention.
    static func draw(_ bounds: CGRect, scale wanted: Double, _ draw: (CGContext) -> Void) -> CIImage? {
        guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { return nil }
        // Huge transforms would ask for giant bitmaps; cap the side and accept softness.
        let scale = min(wanted, maxRasterSide / max(bounds.width, bounds.height))
        let pixels = CGRect(x: bounds.minX * scale, y: bounds.minY * scale, width: bounds.width * scale, height: bounds.height * scale)
            .integral
        guard pixels.width >= 1, pixels.height >= 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: pixels.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -pixels.minX, y: -pixels.minY)
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: pixels.minX, y: -pixels.maxY))
        // The bitmap may have been drawn at a lower scale than asked for; restore the size.
        return scale < wanted ? image.transformed(by: CGAffineTransform(scaleX: wanted / scale, y: wanted / scale)) : image
    }

    static let maxRasterSide = 8192.0

    /// An encoded image asset (pasted pixels, masks, baked paint), decoded lazily by Core
    /// Image and kept so every frame reuses the same `CIImage` (and its GPU cache).
    static func decoded(_ id: AssetID, assets: any AssetStore) -> CIImage? {
        if let hit = imageCache.withLock({ $0[id] }) { return hit }
        guard let data = try? assets.data(id), let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let placed = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        imageCache.withLock { cache in
            // shortcut: drops everything when full; an LRU only matters past 64 distinct assets.
            if cache.count >= 64 { cache.removeAll() }
            cache[id] = placed
        }
        return placed
    }

    /// The same asset as a `CGImage`, for Core Graphics drawing (baked paint).
    static func decodedCG(_ id: AssetID, assets: any AssetStore) -> CGImage? {
        guard let data = try? assets.data(id), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static let imageCache = Mutex<[AssetID: CIImage]>([:])
}

// MARK: - The stack

/// One render of the stack: the document rectangle (Core Image coordinates at `scale`)
/// and where the pixel data lives.
private nonisolated struct Document {
    let rect: CGRect
    let scale: Double
    let assets: any AssetStore

    /// Source pixels (y down) → Core Image coordinates at `scale` (y up).
    var toCI: CGAffineTransform { CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: rect.minX, ty: rect.maxY) }
    var sourceSize: CGSize { CGSize(width: rect.width / scale, height: rect.height / scale) }

    func stack(_ layers: [Layer], over backdrop: CIImage) -> CIImage {
        var below = backdrop
        // What clipped layers are clipped to: the nearest unclipped layer underneath.
        var clipBase = backdrop
        for layer in layers {
            guard layer.isVisible else {
                if !layer.clipsToBelow { clipBase = CIImage.empty() }
                continue
            }
            let (result, placed) = render(layer, over: below, clipBase: layer.clipsToBelow ? clipBase : nil)
            if !layer.clipsToBelow { clipBase = placed }
            // A cache boundary per layer: editing one layer re-renders only what's above it.
            below = result.cropped(to: rect).insertingIntermediate(cache: true)
        }
        return below
    }

    /// `layer` composited over `below`, and the layer's own masked content (for clipping).
    private func render(_ layer: Layer, over below: CIImage, clipBase: CIImage?) -> (CIImage, CIImage) {
        if case .group(let group) = layer.content, group.passThrough {
            let inner = stack(children(of: layer, group), over: below)
            let mask = maskImage(layer, below: below)
            guard layer.opacity < 1 || mask != nil else { return (inner, inner) }
            return (BlendKernels.mix(below, inner, amount: layer.opacity, mask: mask), inner)
        }
        guard var top = content(layer, below: below) else { return (below, CIImage.empty()) }
        if let mask = maskImage(layer, below: below) {
            top = top.applyingFilter(
                "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        }
        if let clipBase {
            top = top.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: clipBase])
        }
        top = top.cropped(to: rect)
        let fill = layer.fillOpacity < 1 ? Self.fade(top, layer.fillOpacity) : top
        let effects = layer.effects.isEmpty || layer.coversDocument ? nil : LayerEffects.parts(layer.effects, of: top, scale: scale)
        guard let effects else {
            return (layer.blend.blend(fill, over: below, opacity: layer.opacity), top)
        }
        var result = below
        for (image, mode) in effects.under { result = mode.blend(image, over: result) }
        result = layer.blend.blend(fill, over: result)
        for image in effects.over { result = Layer.BlendMode.normal.blend(image, over: result) }
        if layer.opacity < 1 { result = BlendKernels.mix(below, result.cropped(to: rect), amount: layer.opacity) }
        return (result, top)
    }

    private func children(of layer: Layer, _ group: GroupSpec) -> [Layer] {
        group.layers.map { child in
            var child = child
            child.transform = child.transform.concatenating(layer.transform)
            return child
        }
    }

    /// The layer's pixels in place (Core Image document coordinates), before mask and effects.
    func content(_ layer: Layer, below: CIImage) -> CIImage? {
        switch layer.content {
        case .adjustment(let spec):
            return adjusted(below, spec).cropped(to: rect)
        case .retouch(let strokes):
            return RetouchRenderer.apply(strokes, to: below, assets: assets, scale: scale).cropped(to: rect)
        case .group(let group):
            return stack(children(of: layer, group), over: CIImage.empty())
        case .fill(let fill):
            let image = GradientRenderer.image(fill, extent: .infinite, scale: scale)
            return image.transformed(by: placement(layer.transform, at: scale)).cropped(to: rect)
        case .pixels(let id):
            guard let image = LayerCompositor.decoded(id, assets: assets) else { return nil }
            // Pixel space is y up; flip it into the layer-space-at-1 convention.
            let local = image.transformed(by: CGAffineTransform(translationX: 0, y: -image.extent.height))
            return placed(local, layer, at: 1)
        case .text, .shape, .paint:
            let rs = rasterScale(layer.transform)
            let image: CIImage? =
                switch layer.content {
                case .text(let text): TextRenderer.image(text, scale: rs)
                case .shape(let shape): ShapeRenderer.image(shape, scale: rs)
                case .paint(let paint): PaintRenderer.image(paint, assets: assets, scale: rs)
                default: nil
                }
            return image.map { placed($0, layer, at: rs) }
        }
    }

    /// Content in layer space at `rs` moved into the document, with its perspective.
    private func placed(_ image: CIImage, _ layer: Layer, at rs: Double) -> CIImage {
        var out = image.transformed(by: placement(layer.transform, at: rs), highQualityDownsample: true)
        if let quad = layer.perspective {
            let local = LayerCompositor.contentBounds(layer.content, assets: assets)
            let box = local.applying(layer.transform).applying(toCI)
            func p(_ point: CGPoint) -> CIVector { CIVector(cgPoint: point.applying(toCI)) }
            out = out.applyingFilter(
                "CIPerspectiveTransformWithExtent",
                parameters: [
                    kCIInputExtentKey: CIVector(cgRect: box),
                    "inputTopLeft": p(quad.topLeft), "inputTopRight": p(quad.topRight),
                    "inputBottomRight": p(quad.bottomRight), "inputBottomLeft": p(quad.bottomLeft),
                ])
        }
        return out.cropped(to: rect)
    }

    /// Layer space at `rs` → document Core Image coordinates.
    func placement(_ transform: CGAffineTransform, at rs: Double) -> CGAffineTransform {
        CGAffineTransform(scaleX: 1 / rs, y: -1 / rs).concatenating(transform).concatenating(toCI)
    }

    /// Draw vector content at the size it will appear, so scaled-up text stays crisp.
    private func rasterScale(_ transform: CGAffineTransform) -> Double {
        let factor = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        return scale * min(16, max(0.01, factor))
    }

    private func adjusted(_ below: CIImage, _ spec: AdjustmentSpec) -> CIImage {
        switch spec {
        case .adjustments(let a): return RenderPipeline.adjusted(below, a, scale: scale)
        case .tone(let tone): return ToneRenderer.apply(tone, to: below, assets: assets)
        case .filter(let preset, let strength): return RenderPipeline.apply(preset, strength: strength, to: below)
        case .blur(let radius):
            return below.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale])
        case .pixelate(let size):
            return below.clampedToExtent().applyingFilter(
                "CIPixellate",
                parameters: [kCIInputScaleKey: max(1, size * scale), kCIInputCenterKey: CIVector(x: rect.minX, y: rect.maxY)])
        }
    }

    // MARK: Masks

    /// The layer's mask over the whole document: an opaque gray image whose values are
    /// the mask's gray levels as painted (sRGB-encoded, like Photoshop), or `nil`.
    func maskImage(_ layer: Layer, below: CIImage) -> CIImage? {
        guard let mask = layer.mask, mask.isEnabled else { return nil }
        let black = CIImage(color: .black).cropped(to: rect)
        var m: CIImage
        switch mask.source {
        case .selection(let spec):
            let selected =
                (try? SelectionRenderer.mask(spec, size: sourceSize, scale: scale, pixels: below, assets: assets)) ?? CIImage(color: .white)
            m = Self.encoded(selected.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)), over: black)
        case .pixels(let id):
            guard let image = LayerCompositor.decoded(id, assets: assets) else { return nil }
            let local = image.transformed(by: CGAffineTransform(translationX: 0, y: -image.extent.height))
            m = Self.encoded(local.transformed(by: placement(layer.transform, at: 1), highQualityDownsample: true), over: black)
        case .vector(let path):
            let rs = rasterScale(layer.transform)
            let cgPath = path.cgPath
            let drawn = LayerCompositor.draw(cgPath.boundingBoxOfPath.insetBy(dx: -1, dy: -1), scale: rs) { ctx in
                ctx.addPath(cgPath)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillPath()
            }
            m = drawn.map { Self.encoded($0.transformed(by: placement(layer.transform, at: rs)), over: black) } ?? black
        case .luminance(let low, let high):
            m = BlendKernels.luminanceMask(below, low: low, high: high).composited(over: black).cropped(to: rect)
        }
        if mask.inverted { m = m.applyingFilter("CIColorInvert") }
        if mask.feather > 0 {
            m = m.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: mask.feather * scale])
        }
        let d = min(1, max(0, mask.density))
        if d < 1 {
            m = m.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: d, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: d, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: d, w: 0), "inputBiasVector": CIVector(x: 1 - d, y: 1 - d, z: 1 - d, w: 0),
                ])
        }
        return m.cropped(to: rect)
    }

    /// Core Image linearizes drawn gray; undo that so a 50 % gray mask hides 50 %.
    private static func encoded(_ mask: CIImage, over black: CIImage) -> CIImage {
        mask.composited(over: black).cropped(to: black.extent).applyingFilter("CILinearToSRGBToneCurve")
    }

    static func fade(_ image: CIImage, _ amount: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, amount))])
    }
}

nonisolated extension Layer {
    /// Adjustment and retouch layers process what's below instead of adding pixels.
    var coversDocument: Bool {
        switch content {
        case .adjustment, .retouch: true
        default: false
        }
    }
}
