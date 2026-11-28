import CoreGraphics
import CoreImage

/// Solid and multi-stop gradient fills.
// Phase 0 stub: the signature is the contract; WP1 fills in the body.
nonisolated enum GradientRenderer {
    /// `fill` covering `extent` (Core Image coordinates at `scale`).
    static func image(_ fill: FillSpec, extent: CGRect, scale: Double) -> CIImage {
        CIImage.empty()
    }
}
