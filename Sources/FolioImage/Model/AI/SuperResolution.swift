import CoreGraphics
import FolioKit

/// 2× upscaling with VideoToolbox's low-latency super-resolution (macOS 26+), tiled,
/// with a Lanczos fallback.
// Phase 0 stub: the signature is the contract; WP4 fills in the body.
nonisolated enum SuperResolution {
    /// True when the machine-learning scaler runs here without a download.
    static var isAvailable: Bool { false }

    static func upscale(_ image: CGImage, factor: Double) async throws -> CGImage {
        throw FolioError("Upscaling isn't available yet.")
    }
}
