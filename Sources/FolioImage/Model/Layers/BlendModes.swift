import CoreImage

// Phase 0 stub: the signature is the contract; WP1 fills in the body.
nonisolated extension Layer.BlendMode {
    /// `top` blended onto `backdrop` with this mode at full opacity (opacity is applied
    /// afterwards with `CIMix`).
    func blend(_ top: CIImage, over backdrop: CIImage) -> CIImage {
        top.composited(over: backdrop)
    }
}
