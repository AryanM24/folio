import CoreGraphics
import CoreImage

/// Pupils from Vision face landmarks, and a desaturate-red kernel around them.
// Phase 0 stub: the signature is the contract; WP4 fills in the body.
nonisolated enum RedEye {
    /// Pupil centers in pixel coordinates of `image` (top-left origin).
    static func pupils(in image: CGImage) throws -> [CGPoint] {
        []
    }

    /// `image` with red removed within `radius` of each pupil (Core Image coordinates).
    static func correct(_ image: CIImage, pupils: [CGPoint], radius: Double, amount: Double) -> CIImage {
        image
    }
}
