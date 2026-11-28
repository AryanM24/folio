import CoreImage

/// Pyramid (push-pull) hole filling: smooth, fast fills for blemishes, dust and cables.
///
/// Pull: the known pixels (weighted by `1 − hole`, premultiplied) are halved again and
/// again, so each coarser level averages whatever is known around a point. Push: from
/// the coarsest level back up, each level's known pixels go over the upsampled coarser
/// fill. Holes get a smooth blend of their surroundings; known pixels stay exact.
/// About 20 ms for 512² (E3). Big holes come out blurry; ``PatchMatch`` adds texture.
nonisolated enum PushPullFill {
    /// `image` with the white parts of `hole` filled from their surroundings.
    static func fill(_ image: CIImage, hole: CIImage) -> CIImage {
        let extent = image.extent.integral
        guard !extent.isInfinite, extent.width >= 2, extent.height >= 2 else { return image }
        // Work at the origin so halving keeps pixel grids aligned.
        let toOrigin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let size = CGRect(origin: .zero, size: extent.size)
        let keep = hole.transformed(by: toOrigin).applyingFilter("CIColorInvert").composited(over: CIImage.white)
            .cropped(to: size)
        // Known pixels, premultiplied by how known they are.
        var levels = [
            image.transformed(by: toOrigin).applyingFilter(
                "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: keep]
            ).cropped(to: size)
        ]
        while let last = levels.last, max(last.extent.width, last.extent.height) > 2 {
            // Bilinear at exactly ½ is a 2×2 box average of premultiplied pixels.
            let half = last.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            let rect = CGRect(
                x: 0, y: 0, width: max(1, (last.extent.width / 2).rounded(.up)), height: max(1, (last.extent.height / 2).rounded(.up)))
            levels.append(half.cropped(to: rect))
        }
        // The coarsest level, normalized by its coverage (`CIColorMatrix` works on
        // unpremultiplied color) and made opaque.
        var filled = opaque(levels.removeLast())
        for level in levels.reversed() {
            let up = filled.clampedToExtent().transformed(by: CGAffineTransform(scaleX: 2, y: 2))
            filled = opaque(level.composited(over: up).cropped(to: level.extent))
        }
        return filled.transformed(by: toOrigin.inverted()).cropped(to: extent)
    }

    private static func opaque(_ image: CIImage) -> CIImage {
        image.applyingFilter(
            "CIColorMatrix",
            parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }
}
