import AVFoundation
import CryptoKit
import FolioKit

/// Reduces a stream of samples to `bins` peak values (max |sample| per bin, 0…1).
///
/// Streaming so a two-hour recording never has to sit in memory: the reader hands over
/// one buffer at a time and only the peaks are kept.
nonisolated struct PeakAccumulator: Sendable {
    let bins: Int
    let expectedSamples: Int
    private(set) var peaks: [Float]
    private var index = 0

    init(expectedSamples: Int, bins: Int) {
        self.bins = max(1, bins)
        self.expectedSamples = max(1, expectedSamples)
        peaks = Array(repeating: 0, count: self.bins)
    }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            // Integer math so bin edges are exact; 64-bit because index × bins exceeds 2^31
            // after about 18 minutes at the analysis rate.
            let bin = min(bins - 1, Int(Int64(index) * Int64(bins) / Int64(expectedSamples)))
            let magnitude = min(1, abs(sample))
            if magnitude > peaks[bin] { peaks[bin] = magnitude }
            index += 1
        }
    }

    static func downsample(_ samples: [Float], bins: Int) -> [Float] {
        var acc = PeakAccumulator(expectedSamples: samples.count, bins: bins)
        samples.withUnsafeBufferPointer { acc.add($0) }
        return acc.peaks
    }
}

/// Waveform peaks for a file, computed off the main thread and cached on disk
/// (`~/Library/Caches/app.folio/Waveforms`) keyed by path, size and modification date,
/// so reopening a long recording draws instantly.
nonisolated enum Waveform {
    static let bins = 2000
    /// Low enough to read an hour of audio in a couple of seconds, high enough that
    /// peaks at 2000 bins look the same as at full rate.
    static let analysisRate: Double = 8000

    static func peaks(for url: URL) async throws -> [Float] {
        let cacheURL = cacheFile(for: url)
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count == bins * MemoryLayout<Float>.size {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let peaks = try await compute(url)
        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? peaks.withUnsafeBytes { try Data($0).write(to: cacheURL, options: .atomic) }
        }
        return peaks
    }

    static func compute(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw FolioError("This file has no sound.") }
        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        // The mixer downmixes every track to mono float at the analysis rate for us.
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: analysisRate,
            ])
        reader.add(output)
        guard reader.startReading() else {
            throw FolioError("Couldn't read the sound: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        var acc = PeakAccumulator(expectedSamples: Int(duration.seconds * analysisRate), bins: bins)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = buffer.dataBuffer else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                    == noErr,
                let pointer, length >= MemoryLayout<Float>.size
            else { continue }
            // A contiguous block is the norm for reader output; a fragmented one would only
            // expose its first segment here, so copy it out in that rare case.
            if CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) {
                pointer.withMemoryRebound(to: Float.self, capacity: length / 4) {
                    acc.add(UnsafeBufferPointer(start: $0, count: length / 4))
                }
            } else {
                var copy = [Float](repeating: 0, count: length / 4)
                _ = copy.withUnsafeMutableBytes { bytes in
                    bytes.baseAddress.map { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: $0) }
                }
                copy.withUnsafeBufferPointer { acc.add($0) }
            }
        }
        if reader.status == .failed {
            throw FolioError("Couldn't read the sound: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        return acc.peaks
    }

    private static func cacheFile(for url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let key =
            "\(url.path(percentEncoded: false))|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(bins)"
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return caches.appending(path: "app.folio/Waveforms/\(name).peaks")
    }
}
