import CoreImage
import FolioKit
import Vision

/// Subject lifting with Vision's foreground instance mask, the engine behind
/// "Copy Subject" in Photos and Preview.
nonisolated enum BackgroundRemoval {
    /// A grayscale mask (white = subject) the same size as `image`.
    ///
    /// Vision runs its model at a fixed internal resolution, so feeding it a
    /// screen-sized proxy and scaling the mask up loses nothing visible and is much
    /// faster than analysing 24 MP.
    static func mask(for image: CGImage) throws -> CIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            throw FolioError("Background removal isn't available on this Mac (\(error.localizedDescription)).")
        }
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw FolioError("Folio couldn't find a clear subject in this image.")
        }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    /// `image` with everything outside `mask` made transparent. The mask is stretched
    /// to the image's extent, so a proxy-resolution mask works for any scale.
    static func apply(mask: CIImage, to image: CIImage) -> CIImage {
        let extent = image.extent
        let scaled = mask.transformed(
            by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height
            )
        ).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return image.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: scaled,
            ])
    }
}
