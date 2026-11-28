import AVFoundation
import CryptoKit
import Foundation

/// Audio checks: decode both files in the same sample format and compare.
nonisolated enum AudioVerify {
    /// Frame count, then every sample, read as `common` from both files.
    static func compare(_ a: URL, _ b: URL, as common: AVAudioCommonFormat) throws -> Verification {
        let x = try AVAudioFile(forReading: a, commonFormat: common, interleaved: false)
        let y = try AVAudioFile(forReading: b, commonFormat: common, interleaved: false)
        guard x.length == y.length, x.processingFormat.channelCount == y.processingFormat.channelCount else {
            return Verification(
                passed: false, checks: ["opens", "frame count differs (\(x.length) vs \(y.length))"],
                metrics: ["frames_in": Double(x.length), "frames_out": Double(y.length)])
        }
        guard let bx = AVAudioPCMBuffer(pcmFormat: x.processingFormat, frameCapacity: AudioConverter.chunk),
            let by = AVAudioPCMBuffer(pcmFormat: y.processingFormat, frameCapacity: AudioConverter.chunk)
        else { throw ConvertError(.internal, "Couldn't allocate an audio buffer.") }
        let width = Int(x.processingFormat.streamDescription.pointee.mBytesPerFrame)  // per channel: non-interleaved
        var differing = 0
        while x.framePosition < x.length {
            try Task.checkCancellation()
            try x.read(into: bx)
            try y.read(into: by)
            let frames = Int(bx.frameLength)
            guard frames > 0, frames == Int(by.frameLength) else { break }
            for (p, q) in zip(
                UnsafeMutableAudioBufferListPointer(bx.mutableAudioBufferList),
                UnsafeMutableAudioBufferListPointer(by.mutableAudioBufferList))
            {
                guard let p = p.mData, let q = q.mData, memcmp(p, q, frames * width) != 0 else { continue }
                differing += countDifferences(p, q, frames, width: width)
            }
        }
        return Verification(
            passed: differing == 0, checks: ["opens", "frame count equal", differing == 0 ? "samples identical" : "samples differ"],
            metrics: ["differing_samples": Double(differing), "frames": Double(x.length)])
    }

    /// What the encoder wrote: one SHA-256 per channel, so read chunking doesn't matter.
    struct Written {
        var frames: Int64
        var channels: [SHA256Digest]
    }

    static func hash(_ buffer: AVAudioPCMBuffer, into hashers: inout [SHA256]) {
        let bytes = Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        for (c, channel) in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).enumerated() where c < hashers.count {
            if let data = channel.mData { hashers[c].update(bufferPointer: UnsafeRawBufferPointer(start: data, count: bytes)) }
        }
    }

    /// The output decodes to exactly the samples the encoder was given.
    static func matches(_ url: URL, as common: AVAudioCommonFormat, _ written: Written) throws -> Verification {
        let file = try AVAudioFile(forReading: url, commonFormat: common, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AudioConverter.chunk) else {
            throw ConvertError(.internal, "Couldn't allocate an audio buffer.")
        }
        var hashers = Array(repeating: SHA256(), count: Int(file.processingFormat.channelCount))
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            hash(buffer, into: &hashers)
        }
        let same = hashers.map { $0.finalize() } == written.channels
        var metrics = ["frames": Double(file.length)]
        if same { metrics["differing_samples"] = 0 }
        return Verification(
            passed: same && file.length == written.frames,
            checks: [
                "opens", file.length == written.frames ? "frame count equal" : "frame count differs",
                same ? "samples identical to the decoded source (SHA-256)" : "samples differ",
            ],
            metrics: metrics)
    }

    /// For lossy output: it opens and lasts as long as the source, give or take one codec packet.
    static func duration(_ a: URL, _ b: URL) throws -> Verification {
        let x = try AVAudioFile(forReading: a), y = try AVAudioFile(forReading: b)
        let dx = Double(x.length) / x.fileFormat.sampleRate, dy = Double(y.length) / y.fileFormat.sampleRate
        let delta = abs(dx - dy)
        return Verification(
            passed: delta <= 4096 / min(x.fileFormat.sampleRate, y.fileFormat.sampleRate), checks: ["opens", "duration±1packet"],
            metrics: ["duration_delta_s": delta])
    }

    // Compares bit patterns, so float NaNs and -0 count as they're stored.
    private static func countDifferences(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ n: Int, width: Int) -> Int {
        func count<T: FixedWidthInteger>(_: T.Type) -> Int {
            let p = a.assumingMemoryBound(to: T.self), q = b.assumingMemoryBound(to: T.self)
            return (0..<n).count { p[$0] != q[$0] }
        }
        switch width {
        case 2: return count(UInt16.self)
        case 4: return count(UInt32.self)
        case 8: return count(UInt64.self)
        default: return count(UInt8.self) / max(width, 1)
        }
    }
}

/// Video checks. Passthrough output is compared without decoding: same compressed samples, same order.
nonisolated enum MediaVerify {
    struct TrackDigest: Equatable {
        var type: AVMediaType
        var samples: Int
        var sha: SHA256Digest
    }

    /// Per track of `types`: sample count and SHA-256 of every compressed sample.
    static func samples(_ a: URL, _ b: URL, types: Set<AVMediaType>) async throws -> Verification {
        let x = try await digests(a, types: types), y = try await digests(b, types: types)
        let passed = !x.isEmpty && x == y
        var checks = ["opens", x.count == y.count ? "track count" : "track count differs (\(x.count) vs \(y.count))"]
        checks.append(x.map(\.samples) == y.map(\.samples) ? "sample count" : "sample count differs")
        checks.append(passed ? "compressed samples identical (SHA-256)" : "compressed samples differ")
        return Verification(
            passed: passed, checks: checks, metrics: ["samples": Double(x.reduce(0) { $0 + $1.samples }), "tracks": Double(x.count)])
    }

    static func digests(_ url: URL, types: Set<AVMediaType>) async throws -> [TrackDigest] {
        let asset = AVURLAsset(url: url)
        var result: [TrackDigest] = []
        for track in try await asset.load(.tracks) where types.contains(track.mediaType) {
            // One reader per track: draining one output of a shared reader can stall the others.
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? ConvertError(.internal, "Couldn't read \(url.lastPathComponent).") }
            var hasher = SHA256()
            var count = 0
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                count += CMSampleBufferGetNumSamples(buffer)
                if let data = buffer.dataBuffer { hasher.update(data: try data.dataBytes()) }
            }
            if reader.status == .failed { throw reader.error ?? ConvertError(.internal, "Couldn't read \(url.lastPathComponent).") }
            result.append(TrackDigest(type: track.mediaType, samples: count, sha: hasher.finalize()))
        }
        return result
    }

    /// The written file's PCM, read back with `settings`, is exactly what was decoded from the
    /// source. (Decoding the source again isn't repeatable for AAC; see `AudioConverter.Plan.digest`.)
    static func pcm(_ url: URL, settings: [String: Any], expected: PCMDigest) async throws -> Verification {
        let x = expected, y = try await pcmDigest(url, settings: settings)
        let passed = x == y
        return Verification(
            passed: passed,
            checks: [
                "opens", x.bytes == y.bytes ? "frame count equal" : "frame count differs", passed ? "samples identical" : "samples differ",
            ],
            metrics: ["bytes": Double(x.bytes)])
    }

    struct PCMDigest: Equatable {
        var bytes: Int
        var sha: SHA256Digest
    }

    private static func pcmDigest(_ url: URL, settings: [String: Any]) async throws -> PCMDigest {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConvertError(.internal, "\(url.lastPathComponent) has no audio.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ConvertError(.internal, "Couldn't read \(url.lastPathComponent).") }
        var hasher = SHA256()
        var bytes = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let data = buffer.dataBuffer else { continue }
            let chunk = try data.dataBytes()
            bytes += chunk.count
            hasher.update(data: chunk)
        }
        return PCMDigest(bytes: bytes, sha: hasher.finalize())
    }

    /// Lossy audio pulled out of a video: it opens and lasts as long as the source.
    static func duration(_ url: URL, expected: Double, tolerance: Double) async throws -> Verification {
        let delta = abs(try await AVURLAsset(url: url).load(.duration).seconds - expected)
        return Verification(passed: delta <= tolerance, checks: ["opens", "duration±1packet"], metrics: ["duration_delta_s": delta])
    }

    /// Re-encoded output: it opens, lasts as long as the source (±1 frame), has the same tracks and the planned size.
    static func transcode(_ url: URL, duration: Double, width: Int, height: Int, tracks: Int, frame: Double) async throws -> Verification {
        let asset = AVURLAsset(url: url)
        let out = try await asset.load(.duration).seconds
        let all = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
        let delta = abs(out - duration)
        let checks = [
            "opens", delta <= frame + 0.001 ? "duration±1frame" : "duration differs by \(delta) s",
            all.count == tracks ? "track count" : "track count differs",
            Int(size.width) == width && Int(size.height) == height ? "dimensions" : "dimensions differ",
        ]
        return Verification(
            passed: !checks.contains { $0.contains("differ") }, checks: checks, metrics: ["duration_delta_s": delta])
    }
}
