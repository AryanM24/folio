import CoreImage

/// Renders a ``ToneSpec``: curves and levels through LUTs, HSL and color balance through
/// runtime kernels, the channel mixer through `CIColorMatrix`, LUTs through
/// `CIColorCubeWithColorSpace`.
// Phase 0 stub: the signature is the contract; WP3 fills in the body.
nonisolated enum ToneRenderer {
    /// `image` with `tone` applied; `assets` holds LUT files.
    static func apply(_ tone: ToneSpec, to image: CIImage, assets: any AssetStore) -> CIImage {
        image
    }
}
