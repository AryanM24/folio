import AVFoundation
import Foundation

/// Shot boundaries ("Detect scenes", split at cuts) from colour histogram changes between
/// consecutive frames.
///
/// The distance is an earth mover's distance on each channel's histogram, so a fade or a
/// camera exposure change, which slides the histogram a little, scores low, while a cut,
/// which replaces it, scores high.
nonisolated enum SceneDetection {
    struct Parameters: Codable, Equatable, Sendable {
        /// 0…1. Distances above this are cuts.
        var threshold = 0.25
        /// Cuts closer together than this are flashes, not shots.
        var minimumShot = Time(value: 1, timescale: 2)
    }

    static let bins = 32

    /// The times where a new shot starts (never zero), in source time.
    static func cuts(
        in url: URL, parameters: Parameters = Parameters(), cache: AnalysisCache? = .shared, progress: AnalysisProgress? = nil
    ) async throws -> [Time] {
        let scores = try await differences(in: url, cache: cache, progress: progress)
        return cuts(scores: scores, parameters: parameters)
    }

    struct Score: Codable, Equatable, Sendable {
        /// The frame that differs from the one before it.
        var time: Time
        var distance: Double
    }

    /// The distance from each frame to the one before, cached so the threshold can change.
    static func differences(in url: URL, cache: AnalysisCache? = .shared, progress: AnalysisProgress? = nil) async throws -> [Score] {
        let compute = {
            var scores: [Score] = []
            var previous: [Double]?
            // 64 px is plenty for colour statistics and decodes fast.
            try await VideoFrameReader.read(url, maxDimension: 64, progress: progress) { time, pixels in
                let histogram = cumulativeHistogram(pixels)
                if let previous, let t = Time(time) { scores.append(Score(time: t, distance: distance(previous, histogram))) }
                previous = histogram
            }
            return scores
        }
        guard let cache else { return try await compute() }
        return try await cache.value(try AnalysisCache.Key("scenes", media: url, parameters: ["\(bins)"]), compute: compute)
    }

    static func cuts(scores: [Score], parameters: Parameters) -> [Time] {
        var cuts: [Time] = []
        for score in scores where score.distance > parameters.threshold {
            if let last = cuts.last, score.time - last < parameters.minimumShot { continue }
            cuts.append(score.time)
        }
        return cuts
    }

    /// Per-channel cumulative histograms of a BGRA frame, each normalised to end at 1.
    static func cumulativeHistogram(_ pixels: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        var counts = [Double](repeating: 0, count: bins * 3)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return counts }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = bytes + y * row + x * 4
                for c in 0..<3 { counts[c * bins + Int(p[c]) * bins / 256] += 1 }
            }
        }
        let total = Double(max(1, width * height))
        for c in 0..<3 {
            var sum = 0.0
            for b in 0..<bins {
                sum += counts[c * bins + b]
                counts[c * bins + b] = sum / total
            }
        }
        return counts
    }

    /// 0 (same colours) … 1 (all black ↔ all white).
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }
}
