import CoreGraphics
import FolioKit
import Foundation
import UniformTypeIdentifiers

/// Every frame of an animated GIF, APNG or HEICS, with its delay, for editing and saving.
// Phase 0 stub: the signature is the contract; WP6 fills in the body.
nonisolated struct AnimatedImage {
    struct Frame {
        var image: CGImage
        /// Seconds.
        var delay: Double
    }

    var frames: [Frame]
    /// 0 = forever.
    var loopCount = 0
}

nonisolated extension AnimatedImage {
    init(data: Data) throws {
        throw FolioError("Folio can't read animation frames yet.")
    }

    func encoded(as type: UTType) throws -> Data {
        throw FolioError("Folio can't save animations yet.")
    }
}
