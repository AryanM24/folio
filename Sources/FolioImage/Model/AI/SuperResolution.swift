import CoreGraphics
import CoreImage
import CoreVideo
import Dispatch
import FolioKit
import VideoToolbox

/// 2× upscaling with VideoToolbox's low-latency super-resolution (macOS 26+), tiled,
/// with a Lanczos fallback.
///
/// The scaler takes at most 768² frames for 2× (E5: none for 1920×1080), so the image
/// goes through in 512² tiles with a 32 px margin each side; neighbouring tiles cross-fade
/// over 16 px inside that margin, so no seam shows. Its buffers are 4:2:0 YUV without
/// alpha, so only its luma detail is kept: the result is the Lanczos upscale plus the
/// machine-learning luma minus Lanczos luma, which keeps full-resolution color and alpha.
/// 4× (`VTSuperResolutionScaler`) needs a model download, so Folio doesn't offer it.
nonisolated enum SuperResolution {
    /// True when the machine-learning scaler runs here without a download.
    static var isAvailable: Bool {
        guard #available(macOS 26, *), VTLowLatencySuperResolutionScalerConfiguration.isSupported else { return false }
        return VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: tile, frameHeight: tile).contains(2)
    }

    /// What the UI calls the method in use: the fallback is plain resampling.
    static var methodTitle: String { isAvailable ? "Machine Learning" : "Standard" }

    static func upscale(_ image: CGImage, factor: Double) async throws -> CGImage {
        guard factor > 1, factor <= 8 else { throw FolioError("Folio can upscale by up to 8×.") }
        let input = CIImage(cgImage: image)
        var output = standard(input, factor: factor)
        if factor == 2, isAvailable, #available(macOS 26, *) {
            let learned = try await tiled(input, factor: 2) { try await VTScaler.shared.process($0) }
            output = detail(from: learned, onto: output)
        }
        let size = CGRect(x: 0, y: 0, width: (Double(image.width) * factor).rounded(), height: (Double(image.height) * factor).rounded())
        let format: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let result = output.cropped(to: size)
        return try await offCooperativePool { try RenderPipeline.rasterize(result, extent: size, format: format, colorSpace: space) }
    }

    /// Lanczos resampling with a light luminance sharpen: the "Standard" method.
    static func standard(_ image: CIImage, factor: Double) -> CIImage {
        image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.3, kCIInputRadiusKey: 1.5 * factor])
    }

    /// `base` with the luma detail of `learned` (both the same size).
    static func detail(from learned: CIImage, onto base: CIImage) -> CIImage {
        guard let kernel = Kernels.kernel(named: "folioLumaDetail", in: kernelSource) as? CIColorKernel,
            let out = kernel.apply(extent: base.extent, arguments: [base, learned])
        else { return base }
        return out
    }

    private static let kernelSource = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        using namespace coreimage;
        [[stitchable]] float4 folioLumaDetail(sample_t base, sample_t learned) {
            float3 w = float3(0.2126, 0.7152, 0.0722);
            float3 c = base.a > 0 ? base.rgb / base.a : float3(0);
            float3 l = learned.a > 0 ? learned.rgb / learned.a : float3(0);
            c = clamp(c + (dot(l, w) - dot(c, w)), 0.0, 1.0);
            return float4(c * base.a, base.a);
        }
        """

    // MARK: Tiling

    /// Input tile size, margin around each tile's core, and cross-fade width (input pixels).
    static let tile = 512
    static let overlap = 32
    static let band = 16

    /// `image` (origin at zero) upscaled by `factor` through `process`, which takes a
    /// `tile`² image at the origin and returns it upscaled (also at the origin). Tiles
    /// past the edges see repeated edge pixels. Each tile is trusted only in its core
    /// plus half the band; the next tile cross-fades in across the band.
    static func tiled(
        _ image: CIImage, factor: Double, tile: Int = tile, overlap: Int = overlap, band: Int = band,
        process: @Sendable (CIImage) async throws -> CIImage
    ) async throws -> CIImage {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        let core = tile - 2 * overlap
        let clamped = image.clampedToExtent()
        var out = CIImage.empty()
        for y in stride(from: 0, to: height, by: core) {
            for x in stride(from: 0, to: width, by: core) {
                try Task.checkCancellation()
                let origin = CGPoint(x: x - overlap, y: y - overlap)
                let input = clamped.cropped(to: CGRect(origin: origin, size: CGSize(width: tile, height: tile)))
                    .transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
                let scaled = try await process(input).transformed(
                    by: CGAffineTransform(translationX: origin.x * factor, y: origin.y * factor))
                let half = Double(band) / 2 * factor
                let coreRect = CGRect(
                    x: Double(x) * factor, y: Double(y) * factor, width: Double(core) * factor, height: Double(core) * factor)
                let piece = scaled.cropped(to: coreRect.insetBy(dx: -half, dy: -half))
                var mask = CIImage.white
                if x > 0 { mask = ramp(from: CGPoint(x: coreRect.minX - half, y: 0), to: CGPoint(x: coreRect.minX + half, y: 0)) }
                if y > 0 {
                    let vertical = ramp(from: CGPoint(x: 0, y: coreRect.minY - half), to: CGPoint(x: 0, y: coreRect.minY + half))
                    mask =
                        x > 0 ? mask.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: vertical]) : vertical
                }
                // Over `out` first, so outside the piece the mask has nothing to fade toward.
                out = piece.composited(over: out).applyingFilter(
                    "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
            }
        }
        return out.cropped(to: CGRect(x: 0, y: 0, width: Double(width) * factor, height: Double(height) * factor))
    }

    /// Black before `start`, white after `end`, linear between.
    private static func ramp(from start: CGPoint, to end: CGPoint) -> CIImage {
        CIImage.black.applyingFilter(
            "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(cgPoint: start), "inputPoint1": CIVector(cgPoint: end),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white,
            ])
    }
}

/// One `VTFrameProcessor` session for 2× on `tile`² frames, reused across calls.
@available(macOS 26, *)
private actor VTScaler {
    static let shared = VTScaler()

    private var processor: VTFrameProcessor?
    private var configuration: VTLowLatencySuperResolutionScalerConfiguration?

    /// `image` (a `tile`² image at the origin) upscaled 2× by the model.
    func process(_ image: CIImage) async throws -> CIImage {
        let side = SuperResolution.tile
        let (processor, configuration) = try session(side: side)
        let source = try buffer(side, side, configuration.sourcePixelBufferAttributes)
        let destination = try buffer(2 * side, 2 * side, configuration.destinationPixelBufferAttributes)
        // Just created, and nothing else touches it until this render returns.
        nonisolated(unsafe) let target = source
        try await offCooperativePool { RenderPipeline.context.render(image, to: target) }
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: .zero),
            let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: .zero)
        else { throw FolioError("Upscaling couldn't prepare its frames.") }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: destinationFrame)
        _ = try await processor.process(parameters: parameters)
        return CIImage(cvPixelBuffer: destination)
    }

    private func session(side: Int) throws -> (VTFrameProcessor, VTLowLatencySuperResolutionScalerConfiguration) {
        if let processor, let configuration { return (processor, configuration) }
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: side, frameHeight: side, scaleFactor: 2)
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: configuration)
        self.processor = processor
        self.configuration = configuration
        return (processor, configuration)
    }

    /// A pixel buffer as the scaler wants it, tagged BT.709 so Core Image converts to
    /// and from YUV the same way on both sides.
    private func buffer(_ width: Int, _ height: Int, _ attributes: [String: Any]) throws -> CVPixelBuffer {
        var attributes = attributes
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        let format = (attributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? kCVPixelFormatType_32BGRA
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
            throw FolioError("Upscaling ran out of memory.")
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
}

/// Runs blocking work (Core Image renders, Vision requests) on a dispatch queue, so it
/// never holds one of Swift concurrency's few cooperative threads while it waits.
nonisolated func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
    }
}
