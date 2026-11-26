import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import FolioKit

/// Still frames: "Save current frame", the filmstrip, and GIFs.
nonisolated enum Frames {
    /// The exact frame at `time`, at full resolution, rotated the way it plays.
    /// Zero tolerance makes AVFoundation decode up to that frame instead of
    /// snapping to the nearest keyframe.
    static func still(_ url: URL, at time: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            return try await generator.image(at: time).image
        } catch {
            throw FolioError("Couldn't read the frame at \(MediaMath.timecode(time)): \(error.localizedDescription)")
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FolioError("Couldn't create “\(url.lastPathComponent)”.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FolioError("Couldn't write “\(url.lastPathComponent)”.") }
    }

    /// Evenly spaced thumbnails, delivered as they decode so the strip fills in left to right.
    /// Keyframe tolerance keeps this fast on long files; thumbnails needn't be exact.
    static func filmstrip(_ url: URL, count: Int, height: CGFloat, deliver: @escaping @MainActor @Sendable (Int, CGImage) -> Void) async {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0, count > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height * 2) // Retina, any aspect
        let times = (0..<count).map { i in
            CMTime(seconds: duration.seconds * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
        }
        for await result in generator.images(for: times) {
            if Task.isCancelled { return }
            guard let image = try? result.image,
                  let index = times.firstIndex(of: result.requestedTime) else { continue }
            await deliver(index, image)
        }
    }
}

/// GIF frame timing, separate so it can be tested.
nonisolated enum GIFTiming {
    /// Sample times (seconds from the start of the range) and per-frame delays.
    ///
    /// GIF delays are whole centiseconds. Rounding each 1/fps delay on its own drifts
    /// (15 fps → 7 cs × 15 = 1.05 s per second), so each delay is the difference of the
    /// rounded *cumulative* times: the animation stays in sync with the source.
    static func frames(duration: Double, fps: Double, maxFrames: Int) -> [(time: Double, delay: Double)] {
        guard duration > 0, fps > 0, maxFrames > 0 else { return [] }
        let count = min(maxFrames, max(1, Int((duration * fps).rounded(.up))))
        let step = duration / Double(count)
        return (0..<count).map { i in
            let start = (Double(i) * step * 100).rounded(), end = (Double(i + 1) * step * 100).rounded()
            return (Double(i) * step, max(2, end - start) / 100) // < 2 cs is treated as 10 cs by browsers
        }
    }
}

/// Writes an animated GIF of part of a video.
nonisolated enum GIFMaker {
    /// Most GIFs people make are seconds long; beyond this the file would be enormous.
    /// Past this, frames are spread over the range (a sped-up GIF) rather than dropped.
    static let maxFrames = 450

    /// What the Make GIF tool converts: as much of the start as fits in `maxFrames`.
    static func toolRange(fps: Double) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: Double(maxFrames) / fps, preferredTimescale: 600))
    }

    static func make(from url: URL, range: CMTimeRange?, fps: Double, width: CGFloat, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await MediaExport.writeAtomically(to: destination) { output in
            try await write(from: url, range: range, fps: fps, width: width, to: output, progress: progress)
        }
    }

    private static func write(from url: URL, range: CMTimeRange?, fps: Double, width: CGFloat, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw FolioError("This file has no video to turn into a GIF.")
        }
        let full = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let span = range.flatMap { MediaMath.clamp($0, to: full.duration) } ?? full
        let plan = GIFTiming.frames(duration: span.duration.seconds, fps: fps, maxFrames: maxFrames)
        guard !plan.isEmpty else { throw FolioError("The selection is too short to make a GIF.") }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width * 4)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, plan.count, nil) else {
            throw FolioError("Couldn't create “\(output.lastPathComponent)”.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        let times = plan.map { span.start + CMTime(seconds: $0.time, preferredTimescale: 600) }
        // Results normally arrive in request order; hold any early arrivals so frames are
        // always added in order.
        var pending: [Int: CGImage] = [:]
        var next = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard let index = times.firstIndex(of: result.requestedTime) else { continue }
            pending[index] = try result.image
            while let image = pending.removeValue(forKey: next) {
                let delay = plan[next].delay
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]] as CFDictionary)
                next += 1
                progress(Double(next) / Double(plan.count))
            }
        }
        guard next == plan.count, CGImageDestinationFinalize(destination) else {
            throw FolioError("Couldn't write the GIF.")
        }
    }
}
