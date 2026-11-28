import CoreImage

/// Feather, expand/contract, smooth and edge-aware refine for any mask.
// Phase 0 stub: the signature is the contract; WP2 fills in the body.
nonisolated enum MaskRefine {
    /// Radii are in source pixels; `scale` is the mask's pixels per source pixel. `guide`
    /// (the image) steers `edge` refinement.
    static func refine(
        _ mask: CIImage, feather: Double = 0, expand: Double = 0, smooth: Double = 0, edge: Double = 0,
        guide: CIImage? = nil, scale: Double
    ) -> CIImage {
        mask
    }
}
