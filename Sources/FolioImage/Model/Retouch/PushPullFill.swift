import CoreImage

/// Pyramid (push-pull) hole filling: smooth, fast fills for blemishes, dust and cables.
// Phase 0 stub: the signature is the contract; WP4 fills in the body.
nonisolated enum PushPullFill {
    /// `image` with the white parts of `hole` filled from their surroundings.
    static func fill(_ image: CIImage, hole: CIImage) -> CIImage {
        image
    }
}
