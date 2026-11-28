import AVFoundation
import CoreImage
import FolioKit
import Vision

/// Person or subject masks for "Remove background", computed once per clip and cached as an
/// 8-bit mask movie, so preview and export read masks instead of running Vision per frame.
///
/// The mask movie is H.264, full-range 4:2:0, upright (the source's rotation applied), at
/// most `maxDimension` on its long side, with the source's frame times. Its luma (plane 0)
/// is coverage: 255 = keep, 0 = background. Scale it to the frame when compositing.
nonisolated enum Segmentation {
    enum Quality: String, Codable, Sendable {
        /// Live preview: fast and rough.
        case fast
        case balanced
        /// The analysis pass: slow and clean.
        case accurate
    }

    struct Parameters: Codable, Equatable, Sendable {
        /// The person model also fires on animals and objects; "subject" lifts whatever is in front.
        var subject = BackgroundSubject.people
        var quality = Quality.accurate
        /// 0 = raw masks (they flicker), towards 1 = steadier but slower to follow motion.
        var smoothing = 0.5
        var maxDimension = 960
    }

    static func cacheKey(_ url: URL, _ parameters: Parameters) throws -> AnalysisCache.Key {
        try AnalysisCache.Key(
            "masks", media: url,
            parameters: [parameters.subject.rawValue, parameters.quality.rawValue, "\(parameters.smoothing)", "\(parameters.maxDimension)"])
    }

    /// The mask movie, if it's been made: what the compositor checks before falling back to
    /// unmasked frames with an "Analysing…" chip.
    static func cachedMaskMovie(for url: URL, parameters: Parameters = Parameters(), cache: AnalysisCache = .shared) -> URL? {
        (try? cacheKey(url, parameters)).flatMap { cache.existing($0, extension: "mov") }
    }

    /// Makes (or finds) the mask movie for `url`.
    static func maskMovie(
        for url: URL, parameters: Parameters = Parameters(), cache: AnalysisCache = .shared, progress: AnalysisProgress? = nil
    ) async throws -> URL {
        try await cache.file(try cacheKey(url, parameters), extension: "mov") { output in
            try await write(url, parameters: parameters, to: output, progress: progress)
        }
    }

    /// One frame's mask, straight from Vision (for live preview). `nil` when nothing was found.
    static func mask(for pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation, parameters: Parameters) throws -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation)
        switch parameters.subject {
        case .people:
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel =
                switch parameters.quality {
                case .fast: .fast
                case .balanced: .balanced
                case .accurate: .accurate
                }
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try handler.perform([request])
            return request.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
        case .subject:
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
            return CIImage(cvPixelBuffer: try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler))
        }
    }

    private static func write(_ url: URL, parameters: Parameters, to output: URL, progress: AnalysisProgress?) async throws {
        let (_, _, info) = try await VideoFrameReader.info(url, maxDimension: parameters.maxDimension)
        let upright = [.left, .right, .leftMirrored, .rightMirrored].contains(info.orientation)
        let width = Int(upright ? info.size.height : info.size.width), height = Int(upright ? info.size.width : info.size.height)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                // Masks are mostly flat; a generous rate keeps edges crisp.
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(500_000, width * height * 8)],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FolioError("Couldn't write the mask movie.") }
        var started = false

        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        let keep = Float(min(0.95, max(0, parameters.smoothing)))
        var smoothed = [Float](repeating: 0, count: width * height)
        var current = [UInt8](repeating: 0, count: width * height)
        var first = true
        do {
            try await VideoFrameReader.read(url, maxDimension: parameters.maxDimension, progress: progress) { time, pixels in
                if !started {
                    writer.startSession(atSourceTime: time)
                    started = true
                }
                current.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
                if let mask = try Self.mask(for: pixels, orientation: info.orientation, parameters: parameters) {
                    let scaled = mask.transformed(
                        by: CGAffineTransform(scaleX: CGFloat(width) / mask.extent.width, y: CGFloat(height) / mask.extent.height))
                    context.render(
                        scaled, toBitmap: &current, rowBytes: width, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .R8,
                        colorSpace: nil)
                }
                // Exponential moving average: steadies edges that flicker frame to frame.
                for i in smoothed.indices {
                    let value = Float(current[i])
                    smoothed[i] = first ? value : smoothed[i] * keep + value * (1 - keep)
                }
                first = false
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard let buffer = try makeFrame(smoothed, width: width, height: height, pool: adaptor.pixelBufferPool),
                    adaptor.append(buffer, withPresentationTime: time)
                else { throw writer.error ?? FolioError("Couldn't write the mask movie.") }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        guard started else {
            writer.cancelWriting()
            throw FolioError("This video has no frames.")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FolioError("Couldn't write the mask movie.") }
    }

    private static func makeFrame(_ values: [Float], width: Int, height: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
            let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return nil }
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            for x in 0..<width { luma[y * row + x] = UInt8(min(255, max(0, values[y * width + x].rounded()))) }
        }
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }
}
