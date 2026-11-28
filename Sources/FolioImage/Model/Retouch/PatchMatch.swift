import CoreGraphics

/// PatchMatch texture synthesis (Barnes et al. 2009) for removing larger objects.
// Phase 0 stub: the signature is the contract; WP4 fills in the body.
nonisolated enum PatchMatch {
    /// `image` with the white parts of `hole` (same size) synthesized from the rest.
    static func fill(_ image: CGImage, hole: CGImage) -> CGImage? {
        nil
    }
}
