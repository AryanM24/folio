import CoreImage

/// Drop shadow, stroke and outer glow around a layer's alpha.
///
/// Like Photoshop, shadows and glows sit under the layer and blend into the backdrop
/// with their own mode; strokes sit on top. All sizes are source pixels.
nonisolated enum LayerEffects {
    /// `layer` (already in place, at `scale`) with `effects` drawn below and around it.
    static func apply(_ effects: [LayerEffect], to layer: CIImage, scale: Double) -> CIImage {
        let parts = parts(effects, of: layer, scale: scale)
        var out = CIImage.empty()
        for (image, mode) in parts.under { out = mode.blend(image, over: out) }
        out = layer.composited(over: out)
        for image in parts.over { out = image.composited(over: out) }
        return out
    }

    /// The effects as images: `under` (with the mode each blends with) go below the layer,
    /// `over` above it. The compositor blends them so fill opacity spares them.
    static func parts(
        _ effects: [LayerEffect], of layer: CIImage, scale: Double
    ) -> (under: [(CIImage, Layer.BlendMode)], over: [CIImage]) {
        var shadows: [(CIImage, Layer.BlendMode)] = [], glows: [(CIImage, Layer.BlendMode)] = [], strokes: [CIImage] = []
        guard !layer.extent.isEmpty, !layer.extent.isInfinite else { return ([], []) }
        for effect in effects {
            switch effect {
            case .dropShadow(let e):
                let blurred = soft(alpha(of: layer, pad: (e.blur + e.distance) * scale + 4), size: e.blur * scale, spread: e.spread)
                let angle = e.angle * .pi / 180
                let offset = CGAffineTransform(translationX: -cos(angle) * e.distance * scale, y: -sin(angle) * e.distance * scale)
                shadows.append((tinted(blurred.transformed(by: offset), e.color, opacity: e.opacity), e.blend))
            case .outerGlow(let e):
                let blurred = soft(alpha(of: layer, pad: e.radius * scale + 4), size: e.radius * scale, spread: e.spread)
                glows.append((tinted(blurred, e.color, opacity: e.opacity), e.blend))
            case .stroke(let e):
                let width = e.width * scale
                guard width > 0 else { continue }
                let a = alpha(of: layer, pad: width + 2)
                let ring: CIImage =
                    switch e.position {
                    case .outside: subtract(a, from: dilate(a, width))
                    case .inside: subtract(erode(a, width), from: a)
                    case .center: subtract(erode(a, width / 2), from: dilate(a, width / 2))
                    }
                strokes.append(tinted(ring, e.color, opacity: e.opacity))
            }
        }
        return (shadows + glows, strokes)
    }

    /// The layer's alpha as an opaque gray image, `pad` pixels larger than the layer.
    private static func alpha(of layer: CIImage, pad: Double) -> CIImage {
        let ones = CIVector(x: 0, y: 0, z: 0, w: 1)
        let gray = layer.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": ones, "inputGVector": ones, "inputBVector": ones,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]
        ).cropped(to: layer.extent)
        let frame = layer.extent.insetBy(dx: -pad, dy: -pad).integral
        return gray.composited(over: CIImage(color: .black).cropped(to: frame))
    }

    /// Photoshop's "size" and "spread": spread grows the solid part before the blur.
    private static func soft(_ mask: CIImage, size: Double, spread: Double) -> CIImage {
        let spread = min(1, max(0, spread))
        let grown = spread > 0 ? dilate(mask, size * spread) : mask
        let blur = size * (1 - spread) / 2
        guard blur > 0.1 else { return grown }
        return grown.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: mask.extent)
    }

    // Morphology filters take small radii; repeat them for wide strokes (discs add up).
    private static func dilate(_ mask: CIImage, _ radius: Double) -> CIImage { morph("CIMorphologyMaximum", mask, radius) }
    private static func erode(_ mask: CIImage, _ radius: Double) -> CIImage { morph("CIMorphologyMinimum", mask, radius) }

    private static func morph(_ name: String, _ mask: CIImage, _ radius: Double) -> CIImage {
        var out = mask, left = radius
        while left > 0.25 {
            let step = min(left, 20)
            out = out.applyingFilter(name, parameters: [kCIInputRadiusKey: step]).cropped(to: mask.extent)
            left -= step
        }
        return out
    }

    private static func subtract(_ inner: CIImage, from outer: CIImage) -> CIImage {
        inner.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: outer]).cropped(to: outer.extent)
    }

    /// `color` where `mask` is white, scaled by `opacity`.
    private static func tinted(_ mask: CIImage, _ color: RGBA, opacity: Double) -> CIImage {
        let solid = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: mask.extent)
        let shaped = solid.applyingFilter(
            "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        return opacity < 1
            ? shaped.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)]) : shaped
    }
}
