import AVFoundation
import CryptoKit
public import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Video conversions, built on AVFoundation passthrough and VideoToolbox.
///
/// Passthrough first: a container change copies the compressed samples (well under a second
/// for any length) and is verified by hashing them. Compressing goes through
/// AVAssetReader → AVAssetWriter with hardware HEVC at constant quality, because the export
/// presets target fixed bitrates and often make files bigger (research §2.7).
public nonisolated enum VideoConverter: FamilyConverter {
    public static let family: Format.Family = .video

    static let containers: [Format] = [.mp4, .mov, .m4v]

    /// Sources AVFoundation can't open: their own converter demuxes them.
    static func delegate(_ format: Format) -> (any FamilyConverter.Type)? {
        [.mkv, .webm].contains(format) ? MatroskaConverter.self : nil
    }

    public static func targets(from source: Format) -> [Target] {
        if let delegate = delegate(source) { return delegate.targets(from: source) }
        guard containers.contains(source) else { return [] }
        let compress = Target(
            to: source, fidelity: .lossy, losslessAvailable: false, drops: ["metadata"],
            notes: "Re-encodes with hardware HEVC; a file that's already compact is kept as is.")
        let remux = containers.filter { $0 != source }.map {
            Target(
                to: $0, fidelity: .lossless, losslessAvailable: true,
                notes: "Remuxes without re-encoding when the codecs fit; otherwise re-encodes to HEVC.")
        }
        return [compress] + remux + [
            Target(
                to: .m4a, fidelity: .lossless, losslessAvailable: true, drops: ["video"],
                notes: "Copies AAC sound as is; other codecs are encoded to AAC."),
            Target(to: .wav, fidelity: .lossless, losslessAvailable: true, drops: ["video"], notes: "Decoded PCM: lossless from here."),
            Target(
                to: .gif, fidelity: .lossy, losslessAvailable: false, drops: ["audio", "anything after 10 s"],
                notes: "480 px at 15 fps (small: 320 px at 10 fps)."),
        ]
    }

    public static func convert(_ job: Job) async throws -> Outcome {
        if let delegate = delegate(job.source) { return try await delegate.convert(job) }
        let asset = AVURLAsset(url: job.input)
        let info = try await Info.load(asset)
        switch job.target {
        case .gif: return try await gif(job, asset, info)
        case .m4a, .wav: return try await extractAudio(job, asset, info)
        default: break
        }
        let downscale = job.maxDimension.map { Double($0) < max(info.size.width, info.size.height) } ?? false
        if job.quality == .lossless, downscale || job.maxBytes != nil {
            throw ConvertError(
                .losslessUnavailable, "Resizing or fitting a size budget means re-encoding, which isn't lossless.",
                hint: "Use quality balanced, or drop max_dimension and max_bytes.")
        }
        if job.quality == .lossless || (job.target != job.source && job.quality == .balanced && job.maxBytes == nil && !downscale) {
            if let outcome = try await remux(job, asset) { return outcome }
            if job.quality == .lossless {
                throw ConvertError(
                    .losslessUnavailable, "\(job.target.title) can't hold this file's codecs (\(info.codecs)) without re-encoding.",
                    hint: "Try mov, which holds almost anything, or quality balanced.")
            }
        }
        return try await transcode(job, asset, info)
    }

    public static func inspect(_ url: URL, format: Format) async throws -> [String: JSONValue] {
        if let delegate = delegate(format) { return try await delegate.inspect(url, format: format) }
        let info = try await Info.load(AVURLAsset(url: url))
        var meta: [String: JSONValue] = [
            "duration_s": .double((info.duration * 1000).rounded() / 1000), "has_audio": .bool(info.audio != nil),
        ]
        if info.video != nil {
            meta["width"] = .int(Int64(info.display.width.rounded()))
            meta["height"] = .int(Int64(info.display.height.rounded()))
            meta["fps"] = .double((info.fps * 100).rounded() / 100)
            meta["video_codec"] = .string(info.videoCodec.map(codecName) ?? "unknown")
        }
        if let codec = info.audioCodec { meta["audio_codec"] = .string(codecName(codec)) }
        if info.duration > 0 { meta["bitrate"] = .int(Int64(Double(Engine.fileSize(url)) * 8 / info.duration)) }
        return meta
    }

    public static func resource(for job: Job) -> Resource {
        if let delegate = delegate(job.source) { return delegate.resource(for: job) }
        return switch job.target {
        case .m4a, .wav: .io
        case .gif: .videoEncode
        default:
            job.quality == .lossless
                || (job.target != job.source && job.quality == .balanced && job.maxBytes == nil && job.maxDimension == nil)
                ? .io : .videoEncode
        }
    }

    // MARK: Remux

    /// Passthrough into the target container, or `nil` when it can't hold the source codecs.
    static func remux(_ job: Job, _ asset: AVURLAsset) async throws -> Outcome? {
        let type = fileType(job.target)
        guard await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: type)
        else {
            return nil
        }
        try preflight(job, bytes: Engine.fileSize(job.input))
        do {
            try await export(asset, to: job.output, as: type, strip: job.stripMetadata, progress: job.progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch  where job.quality != .lossless {
            try? FileManager.default.removeItem(at: job.output)  // the writer fallback needs the path free
            return nil
        }
        let verification = try await MediaVerify.samples(job.input, job.output, types: [.video, .audio])
        return Outcome(
            fidelity: .lossless, method: "remux", details: try await inspect(job.output, format: job.target), verification: verification)
    }

    static func export(
        _ asset: AVAsset, preset: String = AVAssetExportPresetPassthrough, to url: URL, as type: AVFileType, strip: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError(.internal, "Couldn't start the export.")
        }
        if strip { session.metadataItemFilter = .forSharing() }
        // `states(updateInterval:)` exists to be watched while `export` runs; the SDK just doesn't mark the session Sendable.
        let observed = UncheckedSendable(session)
        let watcher = Task {
            for await state in observed.value.states(updateInterval: 0.1) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: type)
    }

    // MARK: Audio out of a video

    static func extractAudio(_ job: Job, _ asset: AVURLAsset, _ info: Info) async throws -> Outcome {
        guard let track = info.audio, let codec = info.audioCodec else {
            throw ConvertError(.unsupportedInput, "This video has no sound to extract.")
        }
        let aac = AudioConverter.isAAC(codec)
        if job.target == .m4a, aac, job.quality != .small, job.maxBytes == nil {
            // The AppleM4A preset on the whole asset passes AAC packets through untouched; an
            // audio-only composition would trim the priming packets instead.
            try await export(
                asset, preset: AVAssetExportPresetAppleM4A, to: job.output, as: .m4a, strip: job.stripMetadata, progress: job.progress)
            let verification = try await MediaVerify.samples(job.input, job.output, types: [.audio])
            let details = try await AudioConverter.inspect(job.output, format: .m4a)
            if verification.passed {
                return Outcome(fidelity: .lossless, method: "extract", details: details, dropped: ["video"], verification: verification)
            }
            // The preset chose to re-encode (unusual AAC flavours): honest label, or refuse at lossless.
            if job.quality == .lossless {
                throw ConvertError(.losslessUnavailable, "This video's AAC couldn't be copied as is.", hint: "Use wav to keep it exact.")
            }
            return Outcome(fidelity: .visuallyLossless, method: "extract", details: details, dropped: ["video"])
        }
        if job.target == .m4a, job.quality == .lossless {
            throw ConvertError(
                .losslessUnavailable, "The sound in this video is \(codecName(codec)), so .m4a would re-encode it.",
                hint: "Use wav to keep it exact.")
        }

        let asbd = info.audioFormat?.audioStreamBasicDescription
        let rate = asbd.map { $0.mSampleRate > 0 ? $0.mSampleRate : 48_000 } ?? 48_000
        let sourceChannels = Int(asbd?.mChannelsPerFrame ?? 2)
        let channels = min(2, max(1, sourceChannels))
        var warnings: [String] = []
        var fidelity: Fidelity
        let pcm: [String: Any]
        let settings: [String: Any]
        if job.target == .wav {
            let isFloat = codec == kAudioFormatLinearPCM && (asbd?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
            let depth = codec == kAudioFormatLinearPCM ? max(16, Int(asbd?.mBitsPerChannel ?? 16)) : 16
            pcm = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: depth,
                AVLinearPCMIsFloatKey: isFloat, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ]
            settings = pcm
            fidelity = .lossless
            if AudioConverter.isLossy(codec) { warnings.append("lossless from here: the source was already lossy") }
        } else {
            let outRate = min(rate, 48_000)
            pcm = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: outRate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ]
            var bitRate = job.quality == .small ? 96_000 : 256_000
            if let maxBytes = job.maxBytes, info.duration > 0 {
                bitRate = min(bitRate, max(32_000, Int(Double(maxBytes) * 8 * 0.97 / info.duration)))
            }
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: outRate, AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate,
            ]
            fidelity = job.quality == .small || AudioConverter.isLossy(codec) ? .lossy : .visuallyLossless
        }
        if sourceChannels > 2 {
            warnings.append("downmixed \(sourceChannels) channels to stereo")
            fidelity = .lossy
        }
        let written = try await rewriteAudio(
            asset, track: track, to: job.output, type: fileType(job.target), pcm: pcm, settings: settings, duration: info.duration,
            progress: job.progress)
        var verification: Verification?
        if fidelity == .lossless {
            verification = try await MediaVerify.pcm(job.output, settings: pcm, expected: written)
        } else if job.verify {
            verification = try await MediaVerify.duration(job.output, expected: info.duration, tolerance: 4096 / min(rate, 48_000))
        }
        return Outcome(
            fidelity: fidelity, method: "extract", details: try await AudioConverter.inspect(job.output, format: job.target),
            dropped: ["video"],
            warnings: warnings, verification: verification)
    }

    /// Decode one audio track to `pcm` and write it with `settings` (PCM again, or AAC).
    /// Returns the SHA-256 and length of the decoded PCM it handed the writer.
    @discardableResult
    static func rewriteAudio(
        _ asset: AVAsset, track: AVAssetTrack, to url: URL, type: AVFileType, pcm: [String: Any], settings: [String: Any], duration: Double,
        progress: @Sendable (Double) -> Void
    ) async throws -> MediaVerify.PCMDigest {
        var hasher = SHA256()
        var bytes = 0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcm)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw ConvertError(
                .internal, "Couldn't convert the audio: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
        // One input only, so a plain loop can't starve an interleaving writer.
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw CancellationError()
            }
            // A failed writer never becomes ready again: stop instead of waiting forever.
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            if writer.status != .writing { break }
            if let data = try buffer.dataBuffer?.dataBytes() {
                hasher.update(data: data)
                bytes += data.count
            }
            guard input.append(buffer) else { break }
            if duration > 0 { progress(min(1, buffer.presentationTimeStamp.seconds / duration)) }
        }
        input.markAsFinished()
        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw ConvertError(
                .internal, "Couldn't convert the audio: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConvertError(.internal, "Couldn't write the audio: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        return MediaVerify.PCMDigest(bytes: bytes, sha: hasher.finalize())
    }

    // MARK: Transcode

    static func transcode(_ job: Job, _ asset: AVURLAsset, _ info: Info) async throws -> Outcome {
        guard let video = info.video else { throw ConvertError(.unsupportedInput, "This file has no video track.") }
        let small = job.quality == .small
        let cap = Double(min(small ? 1920 : 3840, job.maxDimension ?? .max))
        let scale = min(1, cap / max(info.size.width, info.size.height, 1))
        let width = even(info.size.width * scale), height = even(info.size.height * scale)
        let sourceFPS = info.fps > 0 ? info.fps : 30
        let fps = min(sourceFPS, small ? 30 : 60)
        let interval = sourceFPS > fps + 0.5 ? 1 / fps : 0

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: job.output, fileType: fileType(job.target))
        // Scaling in the decoder's output (IOSurface 420v) is about 40 % faster than scaling in the encoder.
        // shortcut: 8-bit 420v tone-clips HDR/10-bit sources to SDR; use 10-bit 420 buffers when HDR output matters.
        let videoOut = AVAssetReaderTrackOutput(
            track: video,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        // Audio: copy it when the container takes it (balanced), else AAC.
        var audioOut: AVAssetReaderOutput?
        var audioIn: AVAssetWriterInput?
        var audioCodec = info.audioCodec.map(codecName)
        var audioBitrate = info.audioBitrate
        if let track = info.audio {
            if !small, let hint = info.audioFormat {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
                if writer.canAdd(input) {
                    audioIn = input
                    audioOut = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                }
            }
            if audioIn == nil {
                let asbd = info.audioFormat?.audioStreamBasicDescription
                let rate = min(48_000, asbd.map { $0.mSampleRate > 0 ? $0.mSampleRate : 48_000 } ?? 48_000)
                let channels = min(2, max(1, Int(asbd?.mChannelsPerFrame ?? 2)))
                audioBitrate = small ? 96_000 : 160_000
                audioOut = AVAssetReaderAudioMixOutput(
                    audioTracks: [track],
                    audioSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                    ])
                audioIn = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                        AVEncoderBitRateKey: audioBitrate,
                    ])
                audioCodec = "aac"
            }
        }

        var properties: [String: Any] = [
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: true, AVVideoExpectedSourceFrameRateKey: fps,
        ]
        var estimate = Engine.fileSize(job.input)
        if let maxBytes = job.maxBytes, info.duration > 0 {
            // 10 % for the container and rate-control overshoot; never above 0.7× the source,
            // where a re-encode stops paying for itself.
            var bitrate = Double(maxBytes) * 8 * 0.9 / info.duration - audioBitrate
            if info.videoBitrate > 0 { bitrate = min(bitrate, info.videoBitrate * 0.7) }
            guard bitrate >= 100_000 else {
                throw ConvertError(
                    .sizeUnreachable,
                    "\(info.duration.rounded()) s of video can't fit in \(ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)).",
                    hint: "Raise max_bytes or trim the clip.")
            }
            properties[AVVideoAverageBitRateKey] = Int(bitrate)
            // A hard one-second cap too: the average alone overshoots on short clips.
            properties[kVTCompressionPropertyKey_DataRateLimits as String] = [bitrate / 8, 1.0]
            estimate = maxBytes
        } else {
            properties[AVVideoQualityKey] = small ? 0.4 : 0.55
        }
        try preflight(job, bytes: estimate)

        let videoIn = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: properties,
            ])
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = info.transform
        writer.add(videoIn)
        if let audioOut, let audioIn {
            audioOut.alwaysCopiesSampleData = false
            reader.add(audioOut)
            writer.add(audioIn)
        }

        try Task.checkCancellation()
        guard reader.startReading() else {
            throw ConvertError(.corruptInput, "Couldn't decode the video: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        guard writer.startWriting() else {
            throw ConvertError(.internal, "Couldn't start the encoder: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)

        let duration = info.duration
        let progress = job.progress
        let halfSource = 0.5 / sourceFPS
        let cancel = UncheckedSendable(reader)
        let watched = UncheckedSendable(writer)
        let lastFrame = UncheckedSendable(LastTime())
        // Each pair is used only by its own pump's serial queue from here on.
        let videoIO = UncheckedSendable((videoOut as AVAssetReaderOutput, videoIn))
        let audioIO = audioOut.flatMap { out in audioIn.map { UncheckedSendable((out, $0)) } }
        let frames = await withTaskCancellationHandler {
            await withTaskGroup(of: (isVideo: Bool, count: Int).self) { group in
                group.addTask {
                    let count = await pump(videoIO, label: "video", writer: watched, reader: cancel) { buffer, state in
                        let pts = buffer.presentationTimeStamp.seconds
                        // Frame-rate cap: keep a frame once its slot comes up, drop the rest.
                        if interval > 0 {
                            if pts < state.next - halfSource { return false }
                            state.next = (pts > state.next + interval ? pts : state.next) + interval
                        }
                        lastFrame.value.seconds = pts
                        if duration > 0 { progress(min(1, pts / duration)) }
                        return true
                    }
                    return (true, count)
                }
                if let audioIO {
                    group.addTask { (false, await pump(audioIO, label: "audio", writer: watched, reader: cancel) { _, _ in true }) }
                }
                var frames = 0
                for await result in group where result.isVideo { frames = result.count }
                return frames
            }
        } onCancel: {
            cancel.value.cancelReading()
        }
        if Task.isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        // Videos with a damaged tail are common (an interrupted recording, a cut download):
        // if decoding fails in the last 2 %, keep everything before it and say so.
        var warnings: [String] = []
        if reader.status == .failed, writer.status != .failed, duration > 0, lastFrame.value.seconds / duration >= 0.98 {
            let missing = max(0.1, duration - lastFrame.value.seconds)
            warnings.append(String(format: "The last %.1f s couldn't be decoded and were left out.", missing))
        } else if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw ConvertError(
                .internal, "The re-encode stopped: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConvertError(.internal, "Couldn't finish the file: \(writer.error?.localizedDescription ?? "unknown error")")
        }

        var details: [String: JSONValue] = [
            "video_codec": "hevc", "width": .int(Int64(width)), "height": .int(Int64(height)), "fps": .double((fps * 100).rounded() / 100),
            "hardware": true, "frames": .int(Int64(frames)),
            "estimated_s": .double((estimatedSeconds(duration: duration, fps: fps, width: width, height: height) * 10).rounded() / 10),
        ]
        if let audioCodec { details["audio_codec"] = .string(audioCodec) }
        if duration > 0 { details["bitrate"] = .int(Int64(Double(Engine.fileSize(job.output)) * 8 / duration)) }
        var verification: Verification?
        if job.verify {
            verification = try await MediaVerify.transcode(
                job.output, duration: duration, width: width, height: height, tracks: info.tracks, frame: 1 / fps)
        }
        if interval > 0 { warnings.append("frame rate capped at \(Int(fps)) fps") }
        return Outcome(
            fidelity: .lossy, method: "transcode", details: details, dropped: ["metadata"], warnings: warnings, verification: verification)
    }

    /// The last video frame's time, written by the video pump and read after it finishes.
    final class LastTime: @unchecked Sendable {
        var seconds = 0.0
    }

    /// Mutable per-pump state, touched only on that pump's serial queue.
    final class PumpState: @unchecked Sendable {
        var next = -Double.infinity
        var appended = 0
        var finished = false
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        /// Registers the pump's continuation; resumes it at once if `finish()` already ran.
        func wait(_ c: CheckedContinuation<Void, Never>) {
            let done = lock.withLock {
                if !finished { continuation = c }
                return finished
            }
            if done { c.resume() }
        }
        /// Resumes the waiting pump exactly once, from the pump's queue or the watchdog.
        func finish() {
            let c: CheckedContinuation<Void, Never>? = lock.withLock {
                finished = true
                defer { continuation = nil }
                return continuation
            }
            c?.resume()
        }
    }

    /// Feeds `input` from `output` whenever the writer wants more, until the reader runs dry.
    /// Video and audio pump concurrently: an interleaving writer stalls one input until the other catches up.
    static func pump(
        _ io: UncheckedSendable<(AVAssetReaderOutput, AVAssetWriterInput)>, label: String,
        writer: UncheckedSendable<AVAssetWriter>, reader: UncheckedSendable<AVAssetReader>,
        keep: @escaping @Sendable (CMSampleBuffer, PumpState) -> Bool
    ) async -> Int {
        let state = PumpState()
        let queue = DispatchQueue(label: "folio.convert.\(label)")
        // requestMediaDataWhenReady stops calling back once the writer fails (an encoder this Mac
        // lacks, a full disk), which would leave this pump waiting forever. Watch for that.
        let watchdog = Task.detached {
            while !state.finished {
                if writer.value.status == .failed || writer.value.status == .cancelled || reader.value.status == .failed {
                    state.finish()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            state.wait(done)
            io.value.1.requestMediaDataWhenReady(on: queue) {
                let (output, input) = io.value
                while !state.finished, input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        state.finish()
                        return
                    }
                    guard keep(buffer, state) else { continue }
                    guard input.append(buffer) else {
                        state.finish()  // the writer failed; the caller reads its error
                        return
                    }
                    state.appended += 1
                }
            }
        }
        watchdog.cancel()
        return state.appended
    }

    /// Seconds a re-encode takes on base Apple silicon: the media engine does about
    /// 450 megapixels a second of HEVC output (210 fps at 1080p, 60 fps at 4K; research §2.7).
    static func estimatedSeconds(duration: Double, fps: Double, width: Int, height: Int) -> Double {
        duration * fps * Double(width * height) / 450_000_000
    }

    /// Refuses before writing when the destination volume can't hold the estimated output.
    static func preflight(_ job: Job, bytes: Int64) throws {
        let folder = job.output.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let important = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        guard let free = important ?? values?.volumeAvailableCapacity.map(Int64.init), bytes > free else { return }
        let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        throw ConvertError(
            .tooLarge, "The output needs about \(fmt(bytes)), and the destination has \(fmt(free)) free.",
            hint: "Free up space, pick another output folder, or use quality small or max_dimension.")
    }

    // MARK: GIF

    static func gif(_ job: Job, _ asset: AVURLAsset, _ info: Info) async throws -> Outcome {
        guard info.video != nil else { throw ConvertError(.unsupportedInput, "This file has no video to turn into a GIF.") }
        let small = job.quality == .small
        let side = CGFloat(min(small ? 320 : 480, job.maxDimension ?? .max))
        let fps: Double = small ? 10 : 15
        let length = min(info.duration, 10)
        var warnings: [String] = []
        if info.duration > 10 { warnings.append("Only the first 10 s became a GIF: longer ones get huge.") }
        let plan = gifFrames(duration: length, fps: fps)
        guard !plan.isEmpty else { throw ConvertError(.unsupportedInput, "The video is too short to make a GIF.") }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let destination = CGImageDestinationCreateWithURL(job.output as CFURL, UTType.gif.identifier as CFString, plan.count, nil)
        else {
            throw ConvertError(.internal, "Couldn't create the GIF.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        let times = plan.map { CMTime(seconds: $0.time, preferredTimescale: 600) }
        // Results normally arrive in request order; hold early arrivals so frames go in in order.
        var pending: [Int: CGImage] = [:]
        var next = 0
        var size = CGSize.zero
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard let index = times.firstIndex(of: result.requestedTime) else { continue }
            pending[index] = try result.image
            while let image = pending.removeValue(forKey: next) {
                size = CGSize(width: image.width, height: image.height)
                let delay = plan[next].delay
                let frame = [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: frame] as CFDictionary)
                next += 1
                job.progress(Double(next) / Double(plan.count))
            }
        }
        guard next == plan.count, CGImageDestinationFinalize(destination) else { throw ConvertError(.internal, "Couldn't write the GIF.") }
        return Outcome(
            fidelity: .lossy, method: "render",
            details: [
                "width": .int(Int64(size.width)), "height": .int(Int64(size.height)), "fps": .double(fps),
                "frames": .int(Int64(plan.count)),
                "duration_s": .double((length * 1000).rounded() / 1000),
            ],
            dropped: ["audio"], warnings: warnings)
    }

    /// Sample times and per-frame delays. GIF delays are whole centiseconds; each delay is the
    /// difference of rounded *cumulative* times, so 15 fps doesn't drift to 1.05 s per second.
    static func gifFrames(duration: Double, fps: Double) -> [(time: Double, delay: Double)] {
        guard duration > 0, fps > 0 else { return [] }
        let count = max(1, Int((duration * fps).rounded(.up)))
        let step = duration / Double(count)
        return (0..<count).map { i in
            let start = (Double(i) * step * 100).rounded(), end = (Double(i + 1) * step * 100).rounded()
            return (Double(i) * step, max(2, end - start) / 100)  // < 2 cs plays as 10 cs in browsers
        }
    }

    // MARK: Helpers

    static func fileType(_ format: Format) -> AVFileType {
        switch format {
        case .mp4: .mp4
        case .m4v: .m4v
        case .m4a: .m4a
        case .wav: .wav
        default: .mov
        }
    }

    static func even(_ value: CGFloat) -> Int { max(2, Int((value / 2).rounded()) * 2) }

    /// What the converter needs to know about a source, loaded once.
    struct Info {
        var duration: Double = 0
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        var size: CGSize = .zero
        var display: CGSize = .zero
        var transform: CGAffineTransform = .identity
        var fps: Double = 0
        var videoCodec: FourCharCode?
        var audioCodec: FourCharCode?
        var audioFormat: CMFormatDescription?
        var videoBitrate: Double = 0
        var audioBitrate: Double = 0
        /// Video plus audio tracks.
        var tracks = 0

        var codecs: String { [videoCodec, audioCodec].compactMap { $0.map(codecName) }.joined(separator: " + ") }

        static func load(_ asset: AVURLAsset) async throws -> Info {
            var info = Info()
            do {
                info.duration = try await asset.load(.duration).seconds
                let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
                info.tracks = videos.count + audios.count
                if let video = videos.first {
                    let (size, transform, fps, rate, formats) = try await video.load(
                        .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
                    info.video = video
                    info.size = size
                    info.transform = transform
                    let rect = CGRect(origin: .zero, size: size).applying(transform)
                    info.display = CGSize(width: abs(rect.width), height: abs(rect.height))
                    info.fps = Double(fps)
                    info.videoBitrate = Double(rate)
                    info.videoCodec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
                }
                if let audio = audios.first {
                    let (rate, formats) = try await audio.load(.estimatedDataRate, .formatDescriptions)
                    info.audio = audio
                    info.audioBitrate = Double(rate)
                    info.audioFormat = formats.first
                    info.audioCodec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
                }
            } catch {
                throw ConvertError(
                    .corruptInput, "Couldn't open “\(asset.url.lastPathComponent)” as video.", hint: error.localizedDescription)
            }
            guard info.video != nil || info.audio != nil else {
                throw ConvertError(.corruptInput, "“\(asset.url.lastPathComponent)” has no video or sound tracks.")
            }
            return info
        }
    }
}

/// Carries a value the SDK hasn't annotated across a task boundary. Use only where the API is
/// documented as safe to call that way (export progress, reader cancellation, writer pumps).
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
