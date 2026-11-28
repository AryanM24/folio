import CoreGraphics
import CoreImage

/// Clone, heal (frequency split), blur, pixelate, redact and red-eye strokes.
///
/// Every stroke is data: an effect image (the picture shifted for clone, blurred for
/// blur, a solid color for redact…) mixed over what is below through the stroke's
/// area mask, in order. Spot heal and remove use the fill stored in `patch`
/// (computed once by the editor); a stroke without one gets a quick push-pull fill.
nonisolated enum RetouchRenderer {
    /// `strokes` applied over `below` (everything under the retouch layer, Core Image
    /// coordinates at `scale`). Spot heal and remove use their stored `patch`.
    static func apply(_ strokes: [RetouchStroke], to below: CIImage, assets: any AssetStore, scale: Double) -> CIImage {
        let extent = below.extent
        guard !strokes.isEmpty, !extent.isInfinite, !extent.isEmpty, scale > 0 else { return below }
        let space = Space(extent: extent, scale: scale)
        var image = below
        for stroke in strokes {
            // shortcut: clone and heal always sample the composite below (`sampleAllLayers`
            // = false needs the base alone, which the compositor doesn't pass in).
            guard let mask = mask(for: stroke, in: space, pixels: image, assets: assets) else { continue }
            let effect = effect(of: stroke, on: image, mask: mask, space: space, assets: assets)
            image = effect.applyingFilter(
                "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask]
            ).cropped(to: extent)
        }
        return image
    }

    /// Source pixels (top-left origin) ↔ Core Image coordinates at `scale`.
    struct Space {
        var extent: CGRect
        var scale: Double
        var sourceSize: CGSize { CGSize(width: extent.width / scale, height: extent.height / scale) }

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * scale, y: extent.maxY - p.y * scale)
        }

        func rect(_ r: CGRect) -> CGRect {
            let r = r.standardized
            return CGRect(
                x: extent.minX + r.minX * scale, y: extent.maxY - r.maxY * scale, width: r.width * scale, height: r.height * scale)
        }

        /// Clone/heal: the picture moved so each destination shows `offset` away from it.
        func translation(_ offset: CGSize) -> CGAffineTransform {
            CGAffineTransform(translationX: -offset.width * scale, y: offset.height * scale)
        }
    }

    // MARK: Effects

    static func effect(of stroke: RetouchStroke, on image: CIImage, mask: CIImage, space: Space, assets: any AssetStore) -> CIImage {
        let extent = space.extent
        switch stroke.tool {
        case .clone:
            return shifted(image, by: stroke.sourceOffset, space: space)
        case .heal:
            let source = shifted(image, by: stroke.sourceOffset, space: space)
            let sigma = max(1, brushRadius(stroke) * space.scale / 2)
            return heal(destination: image, source: source, sigma: sigma)
        case .spotHeal, .remove:
            if let patch = stroke.patch, let placed = placed(patch, assets: assets, space: space) {
                return placed.composited(over: image)
            }
            // No stored fill yet (a live preview): a quick smooth fill from the surroundings.
            return PushPullFill.fill(image, hole: mask)
        case .blur:
            let sigma = (stroke.amount > 0 ? stroke.amount : 12) * space.scale
            return image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        case .pixelate:
            let block = max(1, (stroke.amount > 0 ? stroke.amount : 16) * space.scale)
            return image.clampedToExtent().applyingFilter(
                "CIPixellate", parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: extent.minX, y: extent.maxY)]
            ).cropped(to: extent)
        case .redact:
            let c = stroke.color
            return CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue)).cropped(to: extent)
        case .redEye:
            return RedEye.desaturateRed(image, amount: stroke.amount > 0 ? stroke.amount : 1)
        }
    }

    private static func shifted(_ image: CIImage, by offset: CGSize?, space: Space) -> CIImage {
        image.clampedToExtent().transformed(by: space.translation(offset ?? .zero)).cropped(to: space.extent)
    }

    /// The destination's low frequencies plus the source's detail, `dest_low + (src − src_low)`:
    /// a cheap stand-in for Poisson blending that keeps the destination's color and light.
    static func heal(destination: CIImage, source: CIImage, sigma: Double) -> CIImage {
        let extent = destination.extent
        func low(_ image: CIImage) -> CIImage { image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent) }
        guard let kernel = Kernels.kernel(named: "folioHeal", in: kernelSource) as? CIColorKernel,
            let out = kernel.apply(extent: extent, arguments: [low(destination), source, low(source)])
        else { return source }
        return out
    }

    private static let kernelSource = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        using namespace coreimage;
        [[stitchable]] float4 folioHeal(sample_t destinationLow, sample_t source, sample_t sourceLow) {
            float3 c = destinationLow.rgb + (source.rgb - sourceLow.rgb);
            return float4(clamp(c, 0.0, destinationLow.a), destinationLow.a);
        }
        """

    /// A stored fill, decoded and stretched to its rectangle.
    static func placed(_ patch: PlacedAsset, assets: any AssetStore, space: Space) -> CIImage? {
        guard let data = try? assets.data(patch.asset), let image = CIImage(data: data), !image.extent.isEmpty else { return nil }
        let target = space.rect(patch.rect)
        return image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
                .concatenating(CGAffineTransform(scaleX: target.width / image.extent.width, y: target.height / image.extent.height))
                .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY)),
            highQualityDownsample: true)
    }

    // MARK: Masks

    /// Where `stroke` applies (white), already scaled by its opacity. Redaction is always
    /// hard-edged and fully opaque: a soft or partial redaction would leak what it hides.
    static func mask(for stroke: RetouchStroke, in space: Space, pixels: CIImage? = nil, assets: (any AssetStore)? = nil) -> CIImage? {
        let redact = stroke.tool == .redact
        let hardness = redact ? 1 : min(1, max(0, stroke.hardness))
        let opacity = redact ? 1 : min(1, max(0, stroke.opacity))
        guard opacity > 0 else { return nil }
        var mask: CIImage
        switch stroke.area {
        case .brush(let points, let radius):
            guard !points.isEmpty, radius > 0 else { return nil }
            let feather = (1 - hardness) * radius * space.scale / 2
            guard let brushed = brushMask(points: points, radius: radius, feather: feather, space: space) else { return nil }
            mask = brushed
        case .rect(let rect):
            let r = space.rect(rect).intersection(space.extent)
            guard !r.isNull, !r.isEmpty else { return nil }
            mask = CIImage.white.cropped(to: r)
            let feather = (1 - hardness) * 8 * space.scale
            if feather > 0.3 {
                mask = mask.composited(over: CIImage.black.cropped(to: r.insetBy(dx: -3 * feather, dy: -3 * feather))).applyingGaussianBlur(
                    sigma: feather)
            }
        case .selection(let spec):
            guard
                let selected = try? SelectionRenderer.mask(spec, size: space.sourceSize, scale: space.scale, pixels: pixels, assets: assets)
            else {
                return nil
            }
            mask = selected.transformed(by: CGAffineTransform(translationX: space.extent.minX, y: space.extent.minY))
        }
        mask = mask.composited(over: CIImage.black).cropped(to: space.extent)
        if opacity < 1 {
            let o = CIVector(x: opacity, y: 0, z: 0, w: 0)
            mask = mask.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": o, "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0),
                ])
        }
        return mask
    }

    /// A round brush along `points` (source pixels), drawn with Core Graphics into a
    /// grayscale bitmap the size of the stroke's bounds, then softened by `feather`.
    static func brushMask(points: [CGPoint], radius: Double, feather: Double, space: Space) -> CIImage? {
        let r = radius * space.scale
        let pad = r + 3 * feather + 2
        let ciPoints = points.map(space.point)
        let xs = ciPoints.map(\.x), ys = ciPoints.map(\.y)
        let bounds = CGRect(
            x: xs.min()! - pad, y: ys.min()! - pad, width: xs.max()! - xs.min()! + 2 * pad, height: ys.max()! - ys.min()! + 2 * pad
        ).integral.intersection(space.extent.insetBy(dx: -3 * feather - 2, dy: -3 * feather - 2).integral)
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1,
            let ctx = CGContext(
                data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // Both Core Graphics and Core Image are y-up, so only the origin moves.
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(2 * r)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for p in ciPoints { ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        if ciPoints.count > 1 {
            ctx.addLines(between: ciPoints)
            ctx.strokePath()
        }
        guard let cg = ctx.makeImage() else { return nil }
        let mask = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
        return feather > 0.3 ? mask.applyingGaussianBlur(sigma: feather).cropped(to: bounds) : mask
    }

    /// The brush radius of a stroke in source pixels (rect and selection areas: a
    /// radius that suits their size, for heal's frequency split).
    static func brushRadius(_ stroke: RetouchStroke) -> Double {
        switch stroke.area {
        case .brush(_, let radius): radius
        case .rect(let rect): max(4, min(rect.width, rect.height) / 2)
        case .selection: 16
        }
    }

    /// Where `area` can change pixels, in source pixels; `nil` for a selection (anywhere).
    static func bounds(of area: RetouchStroke.Area) -> CGRect? {
        switch area {
        case .brush(let points, let radius):
            guard let first = points.first else { return nil }
            return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
                .insetBy(dx: -radius, dy: -radius)
        case .rect(let rect): return rect.standardized
        case .selection: return nil
        }
    }
}

nonisolated extension EditRecipe {
    /// True when any layer redacts something. Like `stripMetadata`, a redacted image
    /// must not leave an edit session (recipe plus pristine original) behind, or the
    /// redaction could be undone from it.
    var containsRedaction: Bool {
        func redacts(_ layers: [Layer]) -> Bool {
            layers.contains { layer in
                switch layer.content {
                case .retouch(let strokes): strokes.contains { $0.tool == .redact }
                case .group(let group): redacts(group.layers)
                default: false
                }
            }
        }
        return redacts(layers)
    }
}
