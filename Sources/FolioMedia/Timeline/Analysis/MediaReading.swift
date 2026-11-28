import AVFoundation
import FolioKit
import ImageIO

/// Streams a file's sound as interleaved Float32, one buffer at a time, so an hour of audio
/// never sits in memory. The shared reader under every audio analysis.
nonisolated enum AudioReader {
    /// The number of channels the file's audio has (the widest track), at most `limit`.
    static func channelCount(_ url: URL, limit: Int = 2) async throws -> Int {
        var count = 1
        for track in try await AVURLAsset(url: url).loadTracks(withMediaType: .audio) {
            for description in try await track.load(.formatDescriptions) {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    count = max(count, Int(asbd.mChannelsPerFrame))
                }
            }
        }
        return min(count, limit)
    }

    /// Calls `body` with each buffer of `channels` interleaved samples at `sampleRate`, mixed
    /// from every audio track. Returns the file's duration.
    @discardableResult
    static func read(
        _ url: URL, sampleRate: Double, channels: Int = 1, range: CMTimeRange? = nil, progress: AnalysisProgress? = nil,
        _ body: (UnsafeBufferPointer<Float>) throws -> Void
    ) async throws -> CMTime {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw FolioError("This file has no sound.") }
        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: channels,
                AVSampleRateKey: sampleRate,
            ])
        if let range { reader.timeRange = range }
        reader.add(output)
        guard reader.startReading() else {
            throw FolioError("Couldn't read the sound: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        let expected = max(1, (range?.duration ?? duration).seconds * sampleRate * Double(channels))
        var read = 0
        var copy: [Float] = []
        let pull = UncheckedSendable(output)
        while let buffer = try await offPool({ UncheckedSendable(pull.value.copyNextSampleBuffer()) }).value {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = buffer.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if copy.count < count { copy = [Float](repeating: 0, count: count) }
            try copy.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress,
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base) == noErr
                else { return }
                try body(UnsafeBufferPointer(start: base.assumingMemoryBound(to: Float.self), count: count))
            }
            read += count
            progress?(min(1, Double(read) / expected))
        }
        if reader.status == .failed {
            throw FolioError("Couldn't read the sound: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        return duration
    }
}

/// Decoded video frames for analysis, scaled down by the decoder.
nonisolated enum VideoFrameReader {
    struct Info: Sendable {
        /// The size of the buffers handed out (the file's coded orientation, scaled).
        var size: CGSize
        /// How Vision should turn the buffers to see them upright (the track's rotation).
        var orientation: CGImagePropertyOrientation
        var duration: CMTime
        var nominalFrameRate: Float
        /// The track's own preferred transform, for writers that copy it.
        var transform: CGAffineTransform
    }

    /// The video track's facts, without decoding anything.
    static func info(_ url: URL, maxDimension: Int) async throws -> (AVURLAsset, AVAssetTrack, Info) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FolioError("This file has no video.")
        }
        let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let scale = min(1, Double(maxDimension) / max(1, max(natural.width, natural.height)))
        // Even sizes: the decoder's scaler and the encoders want them.
        let size = CGSize(
            width: max(2, (natural.width * scale / 2).rounded() * 2), height: max(2, (natural.height * scale / 2).rounded() * 2))
        return (
            asset, track,
            Info(size: size, orientation: orientation(of: transform), duration: duration, nominalFrameRate: fps, transform: transform)
        )
    }

    /// Calls `body` with every frame's presentation time and pixels, in decode order
    /// (which is presentation order for reader output). Frames are at most `maxDimension`
    /// on their long side.
    @discardableResult
    static func read(
        _ url: URL, maxDimension: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA, range: CMTimeRange? = nil,
        progress: AnalysisProgress? = nil, _ body: (CMTime, CVPixelBuffer) async throws -> Void
    ) async throws -> Info {
        let (asset, track, info) = try await info(url, maxDimension: maxDimension)
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: Int(info.size.width),
                kCVPixelBufferHeightKey as String: Int(info.size.height),
            ])
        reader.add(output)
        guard reader.startReading() else {
            throw FolioError("Couldn't read the video: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        let span = range ?? CMTimeRange(start: .zero, duration: info.duration)
        let pull = UncheckedSendable(output)
        while let sample = try await offPool({ UncheckedSendable(pull.value.copyNextSampleBuffer()) }).value {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let pixels = sample.imageBuffer else { continue }
            let time = sample.presentationTimeStamp
            try await body(time, pixels)
            if span.duration.seconds > 0 { progress?(min(1, max(0, (time - span.start).seconds / span.duration.seconds))) }
        }
        if reader.status == .failed {
            throw FolioError("Couldn't read the video: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        return info
    }

    /// The EXIF orientation matching a track's rotation (what phones record portrait with).
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (-1, 0, 0, -1): .down
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, 1): .upMirrored
        case (1, 0, 0, -1): .downMirrored
        default: .up
        }
    }
}

/// Runs a blocking call (a decoder read, a Vision request) on a GCD thread and waits for it
/// without holding one of the few threads Swift concurrency shares between every task.
nonisolated func offPool<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let result: UncheckedSendable<Result<T, any Error>> = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: UncheckedSendable(Result { try work() })) }
    }
    return try result.value.get()
}
