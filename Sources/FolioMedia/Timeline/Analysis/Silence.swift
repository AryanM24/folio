import AVFoundation
import Foundation

/// Pauses worth cutting ("Remove pauses"), found from waveform peaks.
///
/// The ranges are already shrunk by `padding` on each side, so a little room stays around
/// every word; pass them to `Project.cut(wordRanges:padding: .zero)`.
nonisolated enum Silence {
    struct Parameters: Codable, Equatable, Sendable {
        /// Peaks below this many dBFS count as silent.
        var threshold = -40.0
        /// Shorter pauses are part of speech and stay.
        var minimumDuration = Time(value: 1, timescale: 2)
        /// Silence kept at each end of a cut.
        var padding = Time(value: 1, timescale: 10)
    }

    /// Peak bins per second: 10 ms, finer than any cut needs.
    static let binsPerSecond = 100.0

    /// Silent stretches of `url`, in source time.
    static func ranges(
        in url: URL, parameters: Parameters = Parameters(), cache: AnalysisCache? = .shared, progress: AnalysisProgress? = nil
    ) async throws -> [TimeRange] {
        let peaks = try await peaks(of: url, cache: cache, progress: progress)
        return ranges(peaks: peaks, binDuration: 1 / binsPerSecond, parameters: parameters)
    }

    /// Fine waveform peaks (`binsPerSecond`), cached: thresholds can change without rereading.
    static func peaks(of url: URL, cache: AnalysisCache? = .shared, progress: AnalysisProgress? = nil) async throws -> [Float] {
        let compute = {
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            let rate = Waveform.analysisRate
            var accumulator = PeakAccumulator(
                expectedSamples: Int(duration * rate), bins: max(1, Int((duration * binsPerSecond).rounded(.up))))
            try await AudioReader.read(url, sampleRate: rate, channels: 1, progress: progress) { accumulator.add($0) }
            return accumulator.peaks
        }
        guard let cache else { return try await compute() }
        return try await cache.value(try AnalysisCache.Key("peaks", media: url, parameters: ["\(binsPerSecond)"]), compute: compute)
    }

    /// Silent stretches in a run of peaks, each `binDuration` seconds long.
    static func ranges(peaks: [Float], binDuration: Double, parameters: Parameters) -> [TimeRange] {
        let threshold = Float(pow(10, parameters.threshold / 20))
        let bin = Time(seconds: binDuration)
        var result: [TimeRange] = []
        var runStart: Int?
        for i in 0...peaks.count {
            let quiet = i < peaks.count && peaks[i] < threshold
            if quiet, runStart == nil { runStart = i }
            guard !quiet, let start = runStart else { continue }
            runStart = nil
            let range = TimeRange(start: bin * Int64(start), end: bin * Int64(i))
            guard range.duration >= parameters.minimumDuration else { continue }
            // The file's own start and end need no room for a word that isn't there.
            let lead = start == 0 ? Time.zero : parameters.padding
            let tail = i == peaks.count ? Time.zero : parameters.padding
            let cut = TimeRange(start: range.start + lead, end: range.end - tail)
            if !cut.isEmpty { result.append(cut) }
        }
        return result
    }
}
