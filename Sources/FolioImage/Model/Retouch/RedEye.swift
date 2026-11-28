import CoreGraphics
import CoreImage
import FolioKit
import Vision

/// Pupils from Vision face landmarks, and a desaturate-red kernel around them.
///
/// `CIRedEyeCorrection` isn't public and auto-adjust only offers red-eye when it finds
/// faces itself (E3), so Folio finds pupils with `VNDetectFaceLandmarksRequest`, stores
/// them as red-eye strokes in source pixels, and renders them with a small kernel that
/// pulls red down to the other channels only where red dominates (skin barely changes).
nonisolated enum RedEye {
    /// Pupil centers in pixel coordinates of `image` (top-left origin).
    static func pupils(in image: CGImage) throws -> [CGPoint] {
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            throw FolioError("Face detection isn't available on this Mac (\(error.localizedDescription)).")
        }
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).flatMap { face -> [CGPoint] in
            [face.landmarks?.leftPupil, face.landmarks?.rightPupil].compactMap { pupil in
                // Vision's image points are bottom-left origin.
                guard let point = pupil?.pointsInImage(imageSize: size).first else { return nil }
                return CGPoint(x: point.x, y: size.height - point.y)
            }
        }
    }

    /// `image` with red removed within `radius` of each pupil (Core Image coordinates).
    static func correct(_ image: CIImage, pupils: [CGPoint], radius: Double, amount: Double) -> CIImage {
        guard !pupils.isEmpty, radius > 0, amount > 0 else { return image }
        let discs = pupils.reduce(CIImage.black.cropped(to: image.extent)) { mask, pupil in
            disc(at: pupil, radius: radius).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        return desaturateRed(image, amount: amount).applyingFilter(
            "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: discs]
        ).cropped(to: image.extent)
    }

    /// White inside `radius`, fading out over its outer fifth.
    static func disc(at center: CGPoint, radius: Double) -> CIImage {
        CIImage.black.applyingFilter(
            "CIRadialGradient",
            parameters: [
                kCIInputCenterKey: CIVector(cgPoint: center), "inputRadius0": radius * 0.8, "inputRadius1": radius,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ]
        ).cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }

    /// Red pulled toward the stronger of green and blue, and darkened a little, where red
    /// dominates; elsewhere unchanged. Everywhere in `image`: callers mask it.
    static func desaturateRed(_ image: CIImage, amount: Double) -> CIImage {
        let amount = min(1, max(0, amount))
        if let kernel = Kernels.kernel(named: "folioRedEye", in: source) as? CIColorKernel,
            let out = kernel.apply(extent: image.extent, arguments: [image, Float(amount)])
        {
            return out
        }
        // Without the kernel: red becomes the green/blue average (also tints skin).
        let r = 1 - amount
        return image.applyingFilter(
            "CIColorMatrix",
            parameters: ["inputRVector": CIVector(x: r, y: amount / 2, z: amount / 2, w: 0)])
    }

    private static let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        using namespace coreimage;
        [[stitchable]] float4 folioRedEye(sample_t s, float amount) {
            float m = max(s.g, s.b);
            float k = smoothstep(0.02, 0.2, s.r - m) * amount;
            float3 c = float3(mix(s.r, m, k), s.g, s.b) * mix(1.0, 0.75, k);
            return float4(c, s.a);
        }
        """
}
