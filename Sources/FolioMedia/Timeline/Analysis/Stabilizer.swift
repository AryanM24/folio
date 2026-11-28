import AVFoundation
import CoreGraphics
import FolioKit
import Vision

/// Per-frame corrections for one source: where to move each frame, and how far to zoom in
/// so the moved edges stay out of sight.
nonisolated struct StabilizationPath: Codable, Equatable, Sendable {
    /// Each frame's presentation time, in source time, ascending.
    var times: [Time]
    /// The translation for each frame, as fractions of the frame, y down.
    var offsets: [Vec2]
    /// ≥ 1. Scale about the frame centre, applied after the offset.
    var zoom: Double

    /// The correction for the frame showing at `time`.
    func offset(at time: Time) -> Vec2 {
        guard !times.isEmpty else { return .zero }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= time { lo = mid } else { hi = mid - 1 }
        }
        return offsets[lo]
    }

    /// The correction as a Core Image transform (y up) for a frame of `size`, upright.
    func transform(at time: Time, size: CGSize) -> CGAffineTransform {
        let o = offset(at: time)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGAffineTransform(translationX: o.x * size.width, y: -o.y * size.height)
            .concatenating(CGAffineTransform(translationX: -centre.x, y: -centre.y))
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
    }
}

/// Stabilization: frame-to-frame registration → camera path → smoothed path → corrections.
///
/// Translation only: it steadies handheld drift and shake, not rotation or rolling shutter.
nonisolated enum Stabilizer {
    /// Registration size: big enough for sub-pixel accuracy at 1080p, small enough to be quick.
    static let analysisDimension = 640
    /// The most the picture is zoomed in to hide moved edges: the 10 % the renderer's
    /// stabilize effect zooms by (EffectGraph), so a clamped correction never shows an edge.
    static let maxZoom = 1.1

    struct Motion: Codable, Equatable, Sendable {
        var times: [Time]
        /// How far the picture moved from the previous frame, fractions of the frame, y down.
        /// The first entry is zero.
        var steps: [Vec2]
    }

    /// The correction path for `url`. `strength` 0…1 sets how much movement is smoothed away.
    static func path(
        for url: URL, strength: Double = 0.7, cache: AnalysisCache? = .shared, progress: AnalysisProgress? = nil
    ) async throws -> StabilizationPath {
        let motion = try await motion(in: url, cache: cache, progress: progress)
        let fps = motion.times.count > 1 ? Double(motion.times.count - 1) / max(0.001, (motion.times.last! - motion.times[0]).seconds) : 30
        return path(motion, strength: strength, framesPerSecond: fps)
    }

    /// The path, if the registration pass has already run.
    static func cachedPath(for url: URL, strength: Double = 0.7, cache: AnalysisCache = .shared) -> StabilizationPath? {
        guard let key = try? motionKey(url), let motion: Motion = cache.cachedValue(key) else { return nil }
        let fps = motion.times.count > 1 ? Double(motion.times.count - 1) / max(0.001, (motion.times.last! - motion.times[0]).seconds) : 30
        return path(motion, strength: strength, framesPerSecond: fps)
    }

    static func motionKey(_ url: URL) throws -> AnalysisCache.Key {
        try AnalysisCache.Key("registration", media: url, parameters: ["\(analysisDimension)"])
    }

    /// Frame-to-frame motion, cached (it doesn't depend on the strength).
    static func motion(in url: URL, cache: AnalysisCache? = .shared, progress: AnalysisProgress? = nil) async throws -> Motion {
        let compute = {
            let orientation = try await VideoFrameReader.info(url, maxDimension: analysisDimension).2.orientation
            var motion = Motion(times: [], steps: [])
            var previous: CVPixelBuffer?
            try await VideoFrameReader.read(url, maxDimension: analysisDimension, progress: progress) { time, pixels in
                guard let t = Time(time) else { return }
                motion.times.append(t)
                motion.steps.append(try previous.map { try Self.step(from: $0, to: pixels, orientation: orientation) } ?? .zero)
                previous = pixels
            }
            return motion
        }
        guard let cache else { return try await compute() }
        return try await cache.value(try motionKey(url), compute: compute)
    }

    /// How far the picture moved from `reference` to `target`, fractions of the frame, y down.
    ///
    /// Vision's alignment transform maps the *target onto the reference*, so it's the motion
    /// with the sign flipped (and y up): content moved by (+12, −7) px comes back as (−12, +7).
    static func step(from reference: CVPixelBuffer, to target: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) throws -> Vec2
    {
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: target, orientation: orientation)
        try VNImageRequestHandler(cvPixelBuffer: reference, orientation: orientation).perform([request])
        let width = Double(CVPixelBufferGetWidth(reference)), height = Double(CVPixelBufferGetHeight(reference))
        let sideways = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        return vector(request.results?.first, width: sideways ? height : width, height: sideways ? width : height)
    }

    /// The same, for still images.
    static func step(from reference: CGImage, to target: CGImage) throws -> Vec2 {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
        try VNImageRequestHandler(cgImage: reference).perform([request])
        return vector(request.results?.first, width: Double(reference.width), height: Double(reference.height))
    }

    private static func vector(_ observation: VNImageTranslationAlignmentObservation?, width: Double, height: Double) -> Vec2 {
        guard let t = observation?.alignmentTransform else { return .zero }
        // Flip the sign (target → reference becomes reference → target), then y up → y down.
        return Vec2(x: -t.tx / width, y: t.ty / height)
    }

    /// Smooths the camera path with a Gaussian (σ grows with `strength`, up to 1 s) and
    /// returns the per-frame corrections from the shaky path to the smooth one.
    static func path(_ motion: Motion, strength: Double, framesPerSecond: Double) -> StabilizationPath {
        var camera: [Vec2] = []
        var position = Vec2.zero
        for step in motion.steps {
            position = Vec2(x: position.x + step.x, y: position.y + step.y)
            camera.append(position)
        }
        let sigma = max(0.5, min(1, max(0, strength)) * framesPerSecond)
        let radius = Int((sigma * 3).rounded(.up))
        let weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +)
        var offsets = camera.indices.map { i -> Vec2 in
            var sx = 0.0, sy = 0.0
            for (k, w) in weights.enumerated() {
                let j = min(camera.count - 1, max(0, i + k - radius))  // hold the ends
                sx += camera[j].x * w
                sy += camera[j].y * w
            }
            return Vec2(x: sx / total - camera[i].x, y: sy / total - camera[i].y)
        }
        // Zoom far enough to hide the largest correction, within the limit; corrections past
        // the limit are clamped so no edge ever shows.
        let limit = (maxZoom - 1) / 2
        let largest = offsets.reduce(0) { max($0, abs($1.x), abs($1.y)) }
        let reach = min(limit, largest)
        offsets = offsets.map { Vec2(x: min(reach, max(-reach, $0.x)), y: min(reach, max(-reach, $0.y))) }
        return StabilizationPath(times: motion.times, offsets: offsets, zoom: 1 + 2 * reach)
    }
}
