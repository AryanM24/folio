import CoreGraphics
import CoreImage

/// Turns a ``SelectionSpec`` into a mask, for the marching ants, masks from selections
/// and every tool that respects a selection.
// Phase 0 stub: the signature is the contract; WP2 fills in the body.
nonisolated enum SelectionRenderer {
    /// `spec` as a grayscale mask (white = selected) over a `size` (source pixels) image
    /// at `scale`, in Core Image coordinates: origin bottom-left, extent = `size` × `scale`.
    /// `pixels` is what the wand, color range, subject and sky shapes analyse, at the same
    /// scale; without it they select nothing. The stub selects everything.
    static func mask(_ spec: SelectionSpec, size: CGSize, scale: Double, pixels: CIImage? = nil) throws -> CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
    }
}
