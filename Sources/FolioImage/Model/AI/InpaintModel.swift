import CoreGraphics
import FolioKit

/// Optional Core ML inpainting (LaMa), off by default and only after an explicit download.
// Phase 0 stub: the signature is the contract; WP4 fills in the body.
nonisolated enum InpaintModel {
    static var isInstalled: Bool { false }

    static func inpaint(_ image: CGImage, hole: CGImage) async throws -> CGImage {
        throw FolioError("The enhanced remove model isn't installed.")
    }
}
