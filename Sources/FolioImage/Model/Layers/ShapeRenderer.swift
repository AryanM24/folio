import CoreImage

/// Vector shapes drawn with Core Graphics, like ``MarkupDrawing``.
// Phase 0 stub: the signature is the contract; WP1 fills in the body.
nonisolated enum ShapeRenderer {
    /// The shape in layer space at `scale`, or `nil` when it draws nothing.
    static func image(_ shape: ShapeSpec, scale: Double) -> CIImage? {
        nil
    }
}
