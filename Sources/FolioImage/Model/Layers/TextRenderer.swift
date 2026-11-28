import CoreGraphics
import CoreImage

/// Text layers through Core Text.
// Phase 0 stub: the signature is the contract; WP1 fills in the body.
nonisolated enum TextRenderer {
    /// The text in layer space at `scale`, or `nil` when it's empty.
    static func image(_ text: TextSpec, scale: Double) -> CIImage? {
        nil
    }

    /// The laid-out size in layer pixels (the box for area text).
    static func size(of text: TextSpec) -> CGSize {
        text.box ?? .zero
    }
}
