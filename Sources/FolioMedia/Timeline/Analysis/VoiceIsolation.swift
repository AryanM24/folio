import AVFoundation
import AudioToolbox
import FolioKit

/// "Isolate voice": the sound re-rendered offline through Apple's Voice Isolation unit
/// (`AUSoundIsolation`) into a 48 kHz CAF in the analysis cache. The timeline builder swaps
/// it in for the source's audio. Where the unit is missing, a noise gate stands in.
nonisolated enum VoiceIsolation {
    enum Method: String, Codable, Sendable {
        /// Voice Isolation when this Mac has it, otherwise the gate.
        case automatic
        case soundIsolation
        case noiseGate
    }

    static let sampleRate = 48_000.0

    private static let component = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    static var isSoundIsolationAvailable: Bool {
        var description = component
        return AudioComponentFindNext(nil, &description) != nil
    }

    static func resolved(_ method: Method) -> Method {
        method == .automatic ? (isSoundIsolationAvailable ? .soundIsolation : .noiseGate) : method
    }

    static func cacheKey(_ url: URL, _ method: Method, gate: NoiseGate.Parameters) throws -> AnalysisCache.Key {
        let m = resolved(method)
        return try AnalysisCache.Key(
            "voice", media: url, parameters: [m.rawValue] + (m == .noiseGate ? ["\(gate.threshold)", "\(gate.reduction)"] : []))
    }

    static func cachedFile(
        for url: URL, method: Method = .automatic, gate: NoiseGate.Parameters = .init(), cache: AnalysisCache = .shared
    ) -> URL? {
        (try? cacheKey(url, method, gate: gate)).flatMap { cache.existing($0, extension: "caf") }
    }

    /// The cleaned-up sound of `url`, same length and timing as the source.
    static func isolate(
        _ url: URL, method: Method = .automatic, gate: NoiseGate.Parameters = .init(), cache: AnalysisCache = .shared,
        progress: AnalysisProgress? = nil
    ) async throws -> URL {
        let method = resolved(method)
        return try await cache.file(try cacheKey(url, method, gate: gate), extension: "caf") { output in
            let channels = try await AudioReader.channelCount(url)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
                throw FolioError("Couldn't prepare the sound.")
            }
            let file = try AVAudioFile(forWriting: output, settings: format.settings)
            switch method {
            case .soundIsolation, .automatic: try await renderIsolated(url, format: format, to: file, progress: progress)
            case .noiseGate: try await renderGated(url, format: format, parameters: gate, to: file, progress: progress)
            }
        }
    }

    // MARK: Voice Isolation

    private static func renderIsolated(_ url: URL, format: AVAudioFormat, to file: AVAudioFile, progress: AnalysisProgress?) async throws {
        guard isSoundIsolationAvailable else { throw FolioError("Voice Isolation isn't available on this Mac.") }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let isolation = AVAudioUnitEffect(audioComponentDescription: component)
        engine.attach(player)
        engine.attach(isolation)
        engine.connect(player, to: isolation, format: format)
        engine.connect(isolation, to: engine.mainMixerNode, format: format)
        let block: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        try engine.start()
        defer { engine.stop() }
        player.play()

        guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block) else {
            throw FolioError("Couldn't prepare the sound.")
        }
        // The unit delays its output; drop that much from the start and render as much again
        // at the end, so the result lines up with the picture.
        var skip = Int((isolation.auAudioUnit.latency * sampleRate).rounded())
        let channels = Int(format.channelCount)

        func render(_ frames: Int) throws {
            var left = frames
            while left > 0 {
                let n = AVAudioFrameCount(min(Int(block), left))
                guard try engine.renderOffline(n, to: rendered) == .success else { throw FolioError("Voice Isolation stopped early.") }
                left -= Int(rendered.frameLength)
                let dropped = min(skip, Int(rendered.frameLength))
                skip -= dropped
                if dropped == Int(rendered.frameLength) { continue }
                try write(rendered, from: dropped, to: file)
            }
        }

        try await AudioReader.read(url, sampleRate: sampleRate, channels: channels, progress: progress) { samples in
            let frames = samples.count / channels
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            deinterleave(samples, channels: channels, into: buffer)
            player.scheduleBuffer(buffer)
            try render(frames)
        }
        try render(Int((isolation.auAudioUnit.latency * sampleRate).rounded()))
    }

    private static func write(_ buffer: AVAudioPCMBuffer, from start: Int, to file: AVAudioFile) throws {
        guard start > 0 else { return try file.write(from: buffer) }
        let count = Int(buffer.frameLength) - start
        guard let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
            let from = buffer.floatChannelData, let to = part.floatChannelData
        else { return }
        for c in 0..<Int(buffer.format.channelCount) { to[c].update(from: from[c] + start, count: count) }
        part.frameLength = AVAudioFrameCount(count)
        try file.write(from: part)
    }

    private static func deinterleave(_ samples: UnsafeBufferPointer<Float>, channels: Int, into buffer: AVAudioPCMBuffer) {
        let frames = samples.count / channels
        guard let data = buffer.floatChannelData else { return }
        for c in 0..<channels {
            for i in 0..<frames { data[c][i] = samples[i * channels + c] }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
    }

    // MARK: Noise gate

    private static func renderGated(
        _ url: URL, format: AVAudioFormat, parameters: NoiseGate.Parameters, to file: AVAudioFile, progress: AnalysisProgress?
    ) async throws {
        let channels = Int(format.channelCount)
        var gate = NoiseGate(parameters: parameters, sampleRate: sampleRate, channels: channels)
        try await AudioReader.read(url, sampleRate: sampleRate, channels: channels, progress: progress) { samples in
            let frames = samples.count / channels
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            var copy = Array(samples)
            gate.process(&copy)
            copy.withUnsafeBufferPointer { deinterleave($0, channels: channels, into: buffer) }
            try file.write(from: buffer)
        }
    }
}

/// A downward expander: quiet stretches (below `threshold`) are turned down by `reduction`,
/// with a fast open and a slow close so word endings aren't chopped.
nonisolated struct NoiseGate: Sendable {
    struct Parameters: Codable, Equatable, Sendable {
        /// dBFS. Blocks quieter than this are noise.
        var threshold = -45.0
        /// dB taken off the noise.
        var reduction = 40.0
    }

    let parameters: Parameters
    let channels: Int
    private let openRate: Float
    private let closeRate: Float
    private let blockFrames: Int
    private let holdBlocks: Int
    private var gain: Float = 1
    private var held = 0

    init(parameters: Parameters, sampleRate: Double, channels: Int) {
        self.parameters = parameters
        self.channels = max(1, channels)
        openRate = Float(1 - exp(-1 / (0.005 * sampleRate)))  // 5 ms
        closeRate = Float(1 - exp(-1 / (0.05 * sampleRate)))  // 50 ms
        blockFrames = max(1, Int(sampleRate / 100))  // 10 ms
        holdBlocks = 10  // 100 ms
    }

    /// Gates interleaved samples in place.
    mutating func process(_ samples: inout [Float]) {
        let threshold = Float(pow(10, parameters.threshold / 20))
        let floor = Float(pow(10, -parameters.reduction / 20))
        let frames = samples.count / channels
        var start = 0
        while start < frames {
            let end = min(frames, start + blockFrames)
            var energy: Float = 0
            for i in start * channels..<end * channels { energy += samples[i] * samples[i] }
            let rms = (energy / Float(max(1, (end - start) * channels))).squareRoot()
            if rms >= threshold { held = holdBlocks } else if held > 0 { held -= 1 }
            let target: Float = held > 0 ? 1 : floor
            let rate = target > gain ? openRate : closeRate
            for f in start..<end {
                gain += (target - gain) * rate
                for c in 0..<channels { samples[f * channels + c] *= gain }
            }
            start = end
        }
    }
}
