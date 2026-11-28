import CoreGraphics
import CoreImage

/// Flood fill by color similarity on a downsampled buffer.
// Phase 0 stub: the signature is the contract; WP2 fills in the body.
nonisolated enum MagicWand {
    /// White where pixels match `seed` (pixel coordinates of `image`, top-left origin).
    static func mask(seed: CGPoint, tolerance: Double, contiguous: Bool, in image: CGImage) -> CIImage? {
        nil
    }
}
