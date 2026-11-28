import AVFoundation
import FolioKit

/// Reversed proxies for clips played backwards. Decoders only run forwards, so playing a
/// long-GOP file in reverse means decoding it a window at a time from the end and writing
/// each window's frames back to front.
///
/// Video and sound are separate files (a video-only .mov and a CAF): one writer fed two
/// tracks in a single loop stalls on interleaving, and the builder inserts them separately
/// anyway. In both, proxy time `t` shows source time `duration − t`; frame `k` from the end
/// of the source is frame `k` of the proxy.
nonisolated enum Reverse {
    /// Frames decoded per window: bounded memory (≈ 90 MB at 1080p) with few re-seeks.
    static let windowFrames = 24

    static func videoKey(_ url: URL, maxDimension: Int) throws -> AnalysisCache.Key {
        try AnalysisCache.Key("reverse-video", media: url, parameters: ["\(maxDimension)"])
    }

    static func audioKey(_ url: URL) throws -> AnalysisCache.Key {
        try AnalysisCache.Key("reverse-audio", media: url)
    }

    static func cachedVideo(for url: URL, maxDimension: Int = 1920, cache: AnalysisCache = .shared) -> URL? {
        (try? videoKey(url, maxDimension: maxDimension)).flatMap { cache.existing($0, extension: "mov") }
    }

    static func cachedAudio(for url: URL, cache: AnalysisCache = .shared) -> URL? {
        (try? audioKey(url)).flatMap { cache.existing($0, extension: "caf") }
    }

    /// The source time a reversed proxy shows at proxy time `t`.
    static func sourceTime(atReversed t: Time, duration: Time) -> Time { duration - t }

    // MARK: Video

    /// The picture of `url`, back to front, H.264 at most `maxDimension` on its long side.
    static func video(
        of url: URL, maxDimension: Int = 1920, cache: AnalysisCache = .shared, progress: AnalysisProgress? = nil
    ) async throws -> URL {
        try await cache.file(try videoKey(url, maxDimension: maxDimension), extension: "mov") { output in
            try await writeVideo(url, maxDimension: maxDimension, to: output, progress: progress)
        }
    }

    private static func writeVideo(_ url: URL, maxDimension: Int, to output: URL, progress: AnalysisProgress?) async throws {
        let (asset, track, info) = try await VideoFrameReader.info(url, maxDimension: maxDimension)
        let (trackRange, minFrame) = try await track.load(.timeRange, .minFrameDuration)
        let timings = try frameTimings(asset: asset, track: track, end: trackRange.end, minFrameDuration: minFrame)
        guard let last = timings.last else { throw FolioError("This video has no frames.") }
        let end = last.start + last.duration

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let width = Int(info.size.width), height = Int(info.size.height)
        let fps = Double(max(1, info.nominalFrameRate))
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(1_000_000, Int(Double(width * height) * fps * 0.15)),
                    // Short GOPs: the proxy is for scrubbing.
                    AVVideoMaxKeyFrameIntervalKey: 15,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        input.transform = info.transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FolioError("Couldn't write the reversed clip.") }
        writer.startSession(atSourceTime: .zero)

        do {
            var upper = timings.count
            while upper > 0 {
                try Task.checkCancellation()
                let lower = max(0, upper - windowFrames)
                let window = Array(timings[lower..<upper])
                let span = CMTimeRange(start: window[0].start, end: window.last!.start + window.last!.duration)
                var frames: [(CMTime, CVPixelBuffer)] = []
                let wanted = Set(window.map(\.start))
                try await VideoFrameReader.read(
                    url, maxDimension: maxDimension, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, range: span
                ) {
                    time, pixels in
                    // A range read also hands back the frame showing at its start; it belongs to the window before.
                    if wanted.contains(time) { frames.append((time, pixels)) }
                }
                for (time, pixels) in frames.reversed() {
                    guard let timing = window.first(where: { $0.start == time }) else { continue }
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                    guard adaptor.append(pixels, withPresentationTime: end - (timing.start + timing.duration)) else {
                        throw writer.error ?? FolioError("Couldn't write the reversed clip.")
                    }
                }
                upper = lower
                progress?(Double(timings.count - upper) / Double(timings.count))
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: end - timings[0].start)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FolioError("Couldn't write the reversed clip.") }
    }

    /// Every frame's presentation time and duration, read from the compressed samples
    /// (nothing is decoded), in presentation order.
    static func frameTimings(asset: AVAsset, track: AVAssetTrack, end: CMTime, minFrameDuration: CMTime) throws -> [CMTimeRange] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FolioError("Couldn't read the video.") }
        var starts: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            if sample.numSamples > 0 { starts.append(sample.presentationTimeStamp) }
        }
        starts.sort()
        return starts.indices.map { i in
            let next = i + 1 < starts.count ? starts[i + 1] : max(end, starts[i] + minFrameDuration)
            return CMTimeRange(start: starts[i], end: next)
        }
    }

    // MARK: Audio

    /// The sound of `url`, back to front, as a 48 kHz CAF.
    static func audio(of url: URL, cache: AnalysisCache = .shared, progress: AnalysisProgress? = nil) async throws -> URL {
        try await cache.file(try audioKey(url), extension: "caf") { output in
            let rate = 48_000.0
            let channels = try await AudioReader.channelCount(url)
            let duration = try await AVURLAsset(url: url).load(.duration)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) else {
                throw FolioError("Couldn't prepare the sound.")
            }
            let file = try AVAudioFile(forWriting: output, settings: format.settings)
            let total = Int64((duration.seconds * rate).rounded())
            let window: Int64 = Int64(rate) * 10
            var upper = total
            while upper > 0 {
                try Task.checkCancellation()
                let lower = max(0, upper - window)
                let frames = Int(upper - lower)
                // Exactly `frames` per window, whatever the decoder's edges, so windows butt.
                var samples = [Float](repeating: 0, count: frames * channels)
                var filled = 0
                let range = CMTimeRange(
                    start: CMTime(value: lower, timescale: Int32(rate)), end: CMTime(value: upper, timescale: Int32(rate)))
                try await AudioReader.read(url, sampleRate: rate, channels: channels, range: range) { chunk in
                    let n = min(chunk.count, samples.count - filled)
                    guard n > 0 else { return }
                    samples.withUnsafeMutableBufferPointer {
                        $0.baseAddress!.advanced(by: filled).update(from: chunk.baseAddress!, count: n)
                    }
                    filled += n
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                    let data = buffer.floatChannelData
                else { throw FolioError("Couldn't prepare the sound.") }
                for f in 0..<frames {
                    for c in 0..<channels { data[c][frames - 1 - f] = samples[f * channels + c] }
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                try file.write(from: buffer)
                upper = lower
                progress?(Double(total - upper) / Double(max(1, total)))
            }
        }
    }

    /// The combined reversed movie, if it has been made.
    static func cachedMedia(for url: URL, maxDimension: Int = 1920, cache: AnalysisCache = .shared) -> URL? {
        guard let key = Self.key(url, maxDimension) else { return nil }
        return cache.existing(key, extension: "mov")
    }

    private static func key(_ url: URL, _ maxDimension: Int) -> AnalysisCache.Key? {
        do { return try mediaKey(url, maxDimension: maxDimension) } catch { return nil }
    }

    static func mediaKey(_ url: URL, maxDimension: Int) throws -> AnalysisCache.Key {
        try AnalysisCache.Key("reverse", media: url, parameters: [String(maxDimension)])
    }

    /// Picture and sound back to front in one movie: what the timeline builder swaps in for
    /// a reversed clip (`RenderAnalysis.reversedMedia`). Both are passed through, not re-encoded.
    static func media(
        of url: URL, maxDimension: Int = 1920, cache: AnalysisCache = .shared, progress: AnalysisProgress? = nil
    ) async throws -> URL {
        let hasSound = try await !AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty
        let share = hasSound ? 0.8 : 1
        let picture = try await video(of: url, maxDimension: maxDimension, cache: cache) { progress?($0 * share) }
        var sound: URL?
        if hasSound { sound = try await audio(of: url, cache: cache) { progress?(0.8 + $0 * 0.2) } }
        return try await cache.file(try mediaKey(url, maxDimension: maxDimension), extension: "mov") { output in
            // A self-contained movie with the samples copied in, not re-encoded.
            let movie = AVMutableMovie()
            movie.defaultMediaDataStorage = AVMediaDataStorage(url: output)
            for file in [picture] + (sound.map { [$0] } ?? []) {
                let asset = AVURLAsset(url: file)
                let duration = try await asset.load(.duration)
                try movie.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: .zero, copySampleData: true)
            }
            try movie.writeHeader(to: output, fileType: .mov, options: .addMovieHeaderToDestination)
        }
    }
}
