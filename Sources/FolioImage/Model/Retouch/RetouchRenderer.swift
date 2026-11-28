import CoreImage

/// Clone, heal (frequency split), blur, pixelate, redact and red-eye strokes.
// Phase 0 stub: the signature is the contract; WP4 fills in the body.
nonisolated enum RetouchRenderer {
    /// `strokes` applied over `below` (everything under the retouch layer, Core Image
    /// coordinates at `scale`). Spot heal and remove use their stored `patch`.
    static func apply(_ strokes: [RetouchStroke], to below: CIImage, assets: any AssetStore, scale: Double) -> CIImage {
        below
    }
}
