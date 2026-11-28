import CoreGraphics
import CoreImage

/// Vision-backed shapes: subject, people and the sky heuristic.
// Phase 0 stub: the signature is the contract; WP2 fills in the body.
nonisolated enum SubjectSelector {
    /// The mask for a `.subject`, `.people` or `.sky` shape at `image`'s size, or `nil`
    /// for other shapes or when nothing is found.
    static func mask(_ shape: SelectionSpec.Shape, in image: CGImage) throws -> CIImage? {
        nil
    }

    /// The foreground instance under `point` (pixel coordinates of `image`, top-left), if any.
    static func instance(at point: CGPoint, in image: CGImage) throws -> Int? {
        nil
    }
}
