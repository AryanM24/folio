import CoreImage

/// Drop shadow, stroke and outer glow around a layer's alpha.
// Phase 0 stub: the signature is the contract; WP1 fills in the body.
nonisolated enum LayerEffects {
    /// `layer` (already in place, at `scale`) with `effects` drawn below and around it.
    static func apply(_ effects: [LayerEffect], to layer: CIImage, scale: Double) -> CIImage {
        layer
    }
}
