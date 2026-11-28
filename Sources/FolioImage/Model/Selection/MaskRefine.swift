import CoreImage

/// Feather, expand/contract, smooth and edge-aware refine for any mask.
nonisolated enum MaskRefine {
    /// Radii are in source pixels; `scale` is the mask's pixels per source pixel. `guide`
    /// (the image) steers `edge` refinement. Applied in that order: expand, smooth, edge,
    /// feather. The result keeps `mask`'s extent.
    static func refine(
        _ mask: CIImage, feather: Double = 0, expand: Double = 0, smooth: Double = 0, edge: Double = 0,
        guide: CIImage? = nil, scale: Double
    ) -> CIImage {
        let extent = mask.extent
        guard !extent.isInfinite, !extent.isEmpty else { return mask }
        var out = mask
        let grow = expand * scale
        if abs(grow) >= 0.5 {
            out = out.clampedToExtent()
                .applyingFilter(grow > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: abs(grow)])
                .cropped(to: extent)
        }
        let round = smooth * scale
        if round >= 0.5 {
            // Blur, then snap back to a hard edge at 50 %: corners and jaggies round off.
            out = threshold(out.clampedToExtent().applyingGaussianBlur(sigma: round).cropped(to: extent))
        }
        let hair = edge * scale
        if hair >= 0.5, let guide {
            out = out.clampedToExtent()
                .applyingFilter(
                    "CIGuidedFilter",
                    parameters: [
                        "inputGuideImage": guide.clampedToExtent(), kCIInputRadiusKey: hair, "inputEpsilon": 0.001,
                    ]
                )
                .applyingFilter("CIColorClamp")
                .cropped(to: extent)
        }
        let soft = feather * scale
        if soft > 0.05 {
            out = out.clampedToExtent().applyingGaussianBlur(sigma: soft / 2).cropped(to: extent)
        }
        return out
    }

    /// Steepens a soft mask around 50 % into a nearly hard edge.
    private static func threshold(_ mask: CIImage) -> CIImage {
        let k: CGFloat = 8
        let diagonal = { (i: Int) in CIVector(x: i == 0 ? k : 0, y: i == 1 ? k : 0, z: i == 2 ? k : 0, w: 0) }
        return mask.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": diagonal(0), "inputGVector": diagonal(1), "inputBVector": diagonal(2),
                "inputBiasVector": CIVector(x: 0.5 - k / 2, y: 0.5 - k / 2, z: 0.5 - k / 2, w: 0),
            ]
        )
        .applyingFilter("CIColorClamp")
    }
}
