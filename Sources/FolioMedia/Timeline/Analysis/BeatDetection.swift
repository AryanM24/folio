import Foundation

/// Onsets (drum hits, note starts) in a music track, so edits can snap to the beat.
///
/// Simple on purpose: the rise in log energy per 10 ms hop, peaks above a local adaptive
/// threshold. It finds hits, not tempo or downbeats.
nonisolated enum BeatDetection {
    struct Parameters: Codable, Equatable, Sendable {
        /// How far above the local average (in standard deviations) a rise must be.
        var sensitivity = 1.5
        /// Onsets closer than this merge (100 ms ≈ 16th notes at 150 BPM).
        var minimumGap = Time(value: 1, timescale: 10)
    }

    struct Onset: Codable, Equatable, Sendable {
        /// Source time.
        var time: Time
        /// The rise in energy, for showing stronger beats bolder.
        var strength: Double
    }

    static let sampleRate = 22_050.0
    static let hop = 220  // ≈ 10 ms

    static func onsets(
        in url: URL, parameters: Parameters = Parameters(), cache: AnalysisCache? = .shared, progress: AnalysisProgress? = nil
    ) async throws -> [Onset] {
        let compute = {
            var energies: [Double] = []
            var sum = 0.0, count = 0
            try await AudioReader.read(url, sampleRate: sampleRate, channels: 1, progress: progress) { samples in
                for s in samples {
                    sum += Double(s * s)
                    count += 1
                    if count == hop {
                        energies.append(sum / Double(hop))
                        (sum, count) = (0, 0)
                    }
                }
            }
            return energies
        }
        let energies: [Double]
        if let cache {
            energies = try await cache.value(try AnalysisCache.Key("energy", media: url, parameters: ["\(hop)"]), compute: compute)
        } else {
            energies = try await compute()
        }
        return onsets(energies: energies, hopDuration: Double(hop) / sampleRate, parameters: parameters)
    }

    /// Onsets in a run of per-hop mean-square energies.
    static func onsets(energies: [Double], hopDuration: Double, parameters: Parameters) -> [Onset] {
        guard energies.count > 2 else { return [] }
        let log = energies.map { 10 * log10($0 + 1e-10) }
        let flux = [0.0] + (1..<log.count).map { max(0, log[$0] - log[$0 - 1]) }
        let window = max(1, Int(0.5 / hopDuration))  // ±0.5 s for the local statistics
        var onsets: [Onset] = []
        for i in 1..<flux.count - 1 where flux[i] > 0 && flux[i] >= flux[i - 1] && flux[i] >= flux[i + 1] {
            let lo = max(0, i - window), hi = min(flux.count, i + window + 1)
            let local = flux[lo..<hi]
            let mean = local.reduce(0, +) / Double(local.count)
            let deviation = (local.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(local.count)).squareRoot()
            // 3 dB: below that a "rise" is noise, whatever the statistics say.
            guard flux[i] > max(3, mean + parameters.sensitivity * deviation) else { continue }
            let onset = Onset(time: Time(seconds: Double(i) * hopDuration), strength: flux[i])
            if let last = onsets.last, onset.time - last.time < parameters.minimumGap {
                if onset.strength > last.strength { onsets[onsets.count - 1] = onset }
                continue
            }
            onsets.append(onset)
        }
        return onsets
    }
}
