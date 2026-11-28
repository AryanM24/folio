import CoreGraphics
import CoreImage

/// Renders the layer stack over the developed base image.
// Phase 0 stub: the signature is the contract; WP1 fills in the body.
nonisolated enum LayerCompositor {
    /// `layers` (bottom → top, source pixels) composited over `base`: the developed
    /// original at `scale`, in Core Image coordinates (origin bottom-left, extent
    /// = source size × `scale`). Returns the same extent.
    static func composite(base: CIImage, layers: [Layer], assets: any AssetStore, scale: Double) -> CIImage {
        base
    }

    /// The layer's visible bounds in source pixels (after its transform), for transform
    /// handles and snapping. `.null` for layers that cover the document (fills, adjustments).
    static func bounds(of layer: Layer, assets: any AssetStore) -> CGRect {
        .null
    }
}
