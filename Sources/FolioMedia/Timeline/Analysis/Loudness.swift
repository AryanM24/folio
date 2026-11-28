import Foundation

/// Integrated loudness (ITU-R BS.1770-4 / EBU R128) and the gain that brings a file to a
/// delivery target such as −14 LUFS (streaming) or −16 LUFS (podcasts).
nonisolated enum Loudness {
    struct Measurement: Codable, Equatable, Sendable {
        /// LUFS; `-infinity` for silence or files under 400 ms.
        var integrated: Double
        /// Sample peak, dBFS.
        var peak: Double
    }

    static let sampleRate = 48_000.0

    static func measure(_ url: URL, cache: AnalysisCache? = .shared, progress: AnalysisProgress? = nil) async throws -> Measurement {
        let compute = {
            let channels = try await AudioReader.channelCount(url)
            var meter = Meter(channels: channels)
            try await AudioReader.read(url, sampleRate: sampleRate, channels: channels, progress: progress) { meter.add($0) }
            return meter.measurement
        }
        guard let cache else { return try await compute() }
        return try await cache.value(try AnalysisCache.Key("loudness", media: url), compute: compute)
    }

    /// dB to add to reach `target` LUFS, held back so the peak stays under `ceiling` dBFS.
    /// shortcut: uses the sample peak, not true peak (no 4× oversampling); allow ~0.5 dB more
    /// headroom on bright material. Zero for silence.
    static func normalizationGain(for measurement: Measurement, target: Double = -14, ceiling: Double = -1) -> Double {
        guard measurement.integrated.isFinite else { return 0 }
        return min(target - measurement.integrated, ceiling - measurement.peak)
    }

    /// Streaming BS.1770 meter over interleaved 48 kHz samples.
    struct Meter: Sendable {
        let channels: Int
        private var filters: [KWeighting]
        /// Mean square (summed over channels) of each 100 ms quarter-block.
        private var quarters: [Double] = []
        private var sum = 0.0
        private var count = 0
        private var peak: Float = 0
        private static let quarter = Int(sampleRate / 10)

        init(channels: Int) {
            self.channels = max(1, channels)
            filters = Array(repeating: KWeighting(), count: self.channels)
        }

        mutating func add(_ samples: UnsafeBufferPointer<Float>) {
            let frames = samples.count / channels
            for f in 0..<frames {
                for c in 0..<channels {
                    let x = samples[f * channels + c]
                    peak = max(peak, abs(x))
                    let y = filters[c].process(Double(x))
                    sum += y * y
                }
                count += 1
                if count == Self.quarter {
                    quarters.append(sum / Double(count))
                    sum = 0
                    count = 0
                }
            }
        }

        var measurement: Measurement {
            // 400 ms blocks with 75 % overlap = four consecutive quarters.
            let blocks = quarters.count < 4 ? [] : (0...(quarters.count - 4)).map { quarters[$0..<$0 + 4].reduce(0, +) / 4 }
            func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
            let absolute = blocks.filter { lufs($0) > -70 }
            let peakDB = peak > 0 ? 20 * log10(Double(peak)) : -Double.infinity
            guard !absolute.isEmpty else { return Measurement(integrated: -.infinity, peak: peakDB) }
            let relative = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
            let gated = absolute.filter { lufs($0) > relative }
            return Measurement(integrated: lufs(gated.reduce(0, +) / Double(max(1, gated.count))), peak: peakDB)
        }
    }

    /// The two-stage K-weighting filter (high shelf + high pass), BS.1770 coefficients at 48 kHz.
    struct KWeighting: Sendable {
        private var shelf = Biquad(b: (1.53512485958697, -2.69169618940638, 1.19839281085285), a: (-1.69065929318241, 0.73248077421585))
        private var highPass = Biquad(b: (1, -2, 1), a: (-1.99004745483398, 0.99007225036621))

        mutating func process(_ x: Double) -> Double { highPass.process(shelf.process(x)) }
    }

    struct Biquad: Sendable {
        let b: (Double, Double, Double)
        let a: (Double, Double)
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(b: (Double, Double, Double), a: (Double, Double)) {
            self.b = b
            self.a = a
        }

        mutating func process(_ x: Double) -> Double {
            let y = b.0 * x + b.1 * x1 + b.2 * x2 - a.0 * y1 - a.1 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            return y
        }
    }
}
