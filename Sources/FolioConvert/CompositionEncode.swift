public import AVFoundation
import VideoToolbox

/// How `CompositionEncoder` writes a file. Pure data, so callers can build it from a preset.
public nonisolated struct EncodeSettings: Sendable, Equatable {
    public enum Codec: String, Sendable, CaseIterable {
        case hevc, h264
        /// HEVC with an alpha channel: transparent output after background removal. Few players show the alpha.
        case hevcWithAlpha
        case proRes422, proRes4444

        var avCodec: AVVideoCodecType {
            switch self {
            case .hevc: .hevc
            case .h264: .h264
            case .hevcWithAlpha: .hevcWithAlpha
            case .proRes422: .proRes422
            case .proRes4444: .proRes4444
            }
        }

        var isProRes: Bool { self == .proRes422 || self == .proRes4444 }
        var hasAlpha: Bool { self == .hevcWithAlpha || self == .proRes4444 }
    }

    /// HDR transfer function. Either one means 10-bit HEVC with BT.2020 colour.
    public enum HDR: String, Sendable { case hlg, pq }

    public struct Video: Sendable, Equatable {
        public var codec: Codec
        /// Output frame size; `nil` keeps the composition's render size. The picture is fitted, never stretched.
        public var width: Int?
        public var height: Int?
        /// Frames above this rate are dropped.
        public var maxFrameRate: Double?
        /// Constant quality, 0…1. Ignored for ProRes and when `maxBytes` is set.
        public var quality: Double
        /// 10-bit 4:2:0 (HEVC only); implied by `hdr`.
        public var tenBit: Bool
        public var hdr: HDR?

        public init(
            codec: Codec = .hevc, width: Int? = nil, height: Int? = nil, maxFrameRate: Double? = nil, quality: Double = 0.55,
            tenBit: Bool = false, hdr: HDR? = nil
        ) {
            self.codec = codec
            self.width = width
            self.height = height
            self.maxFrameRate = maxFrameRate
            self.quality = quality
            self.tenBit = tenBit
            self.hdr = hdr
        }
    }

    public enum Audio: Sendable, Equatable {
        case none
        case aac(bitrate: Int)
        /// 16-bit little-endian PCM (WAV, ProRes masters).
        case pcm
    }

    /// `nil` writes sound only.
    public var video: Video?
    public var audio: Audio
    public var fileType: AVFileType
    /// Compress to fit this many bytes (video and audio together).
    public var maxBytes: Int64?

    public init(video: Video? = Video(), audio: Audio = .aac(bitrate: 160_000), fileType: AVFileType = .mp4, maxBytes: Int64? = nil) {
        self.video = video
        self.audio = audio
        self.fileType = fileType
        self.maxBytes = maxBytes
    }
}

/// What an encode produced.
public nonisolated struct EncodeResult: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var frames: Int
    /// The average video bitrate asked of the encoder when fitting a budget.
    public var targetBitrate: Int?
}

/// Encodes any composition (an `AVComposition` with its video composition and audio mix, or
/// a plain asset) through AVAssetReader → AVAssetWriter, for what export presets can't do:
/// constant quality, a byte budget, a frame-rate cap, 10-bit HDR and alpha.
///
/// It shares `VideoConverter.pump` (and its writer watchdog) with `transcode`. A failed or
/// cancelled encode removes whatever it wrote at `url`.
public nonisolated enum CompositionEncoder {
    public static func encode(
        _ asset: AVAsset, videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil, timeRange: CMTimeRange? = nil,
        settings: EncodeSettings, to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> EncodeResult {
        do {
            return try await write(asset, videoComposition, audioMix, timeRange, settings, url, progress)
        } catch {
            let fm = FileManager.default
            try? fm.removeItem(at: url)
            // A cancelled fast-start writer can leave its "<name>.sb-…" scratch file beside the output.
            let folder = url.deletingLastPathComponent()
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(url.lastPathComponent + ".sb-") {
                try? fm.removeItem(at: folder.appending(path: name))
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// The average video bitrate that fits `maxBytes` after the audio, with 10 % for the
    /// container and rate-control overshoot (the same budget `transcode` uses).
    static func bitrate(fitting maxBytes: Int64, seconds: Double, audioBitrate: Double) throws -> Double {
        let bitrate = seconds > 0 ? Double(maxBytes) * 8 * 0.9 / seconds - audioBitrate : 0
        guard bitrate >= 100_000 else {
            throw ConvertError(
                .sizeUnreachable,
                "\(seconds.rounded()) s of video can't fit in \(ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)).",
                hint: "Allow a bigger file or shorten the export.")
        }
        return bitrate
    }

    private static func write(
        _ asset: AVAsset, _ composition: AVVideoComposition?, _ audioMix: AVAudioMix?, _ timeRange: CMTimeRange?, _ settings: EncodeSettings,
        _ url: URL, _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> EncodeResult {
        let duration = try await asset.load(.duration)
        let range = timeRange ?? CMTimeRange(start: .zero, duration: duration)
        let seconds = range.duration.seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: url, fileType: settings.fileType)
        writer.shouldOptimizeForNetworkUse = true

        var audioOut: AVAssetReaderOutput?
        var audioIn: AVAssetWriterInput?
        var audioBitrate = 0.0
        if settings.audio != .none, !audioTracks.isEmpty {
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ]
            let mixOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
            mixOut.audioMix = audioMix
            mixOut.alwaysCopiesSampleData = false
            var encoded = pcm
            if case .aac(let rate) = settings.audio {
                audioBitrate = Double(rate)
                encoded = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: rate]
            } else {
                audioBitrate = 48_000 * 2 * 16
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encoded)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ConvertError(.unsupportedPair, "This container can't hold that sound format.") }
            reader.add(mixOut)
            writer.add(input)
            (audioOut, audioIn) = (mixOut, input)
        }

        var videoOut: AVAssetReaderOutput?
        var videoIn: AVAssetWriterInput?
        var size = CGSize.zero
        var interval = 0.0
        var half = 0.0
        var targetBitrate: Int?
        if let video = settings.video {
            guard !videoTracks.isEmpty else { throw ConvertError(.unsupportedInput, "There's no picture to encode.") }
            let tenBit = video.tenBit || video.hdr != nil
            if tenBit, video.codec != .hevc {
                throw ConvertError(.unsupportedPair, "10-bit and HDR export need HEVC.", hint: "Pick HEVC, or turn HDR off.")
            }
            if video.codec.isProRes, settings.maxBytes != nil {
                throw ConvertError(.unsupportedPair, "ProRes can't be squeezed to a size.", hint: "Pick HEVC or H.264.")
            }
            let built: AVVideoComposition
            if let composition {
                built = composition
            } else {
                built = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
            }
            let render = built.renderSize
            size = CGSize(width: even(Double(video.width ?? Int(render.width))), height: even(Double(video.height ?? Int(render.height))))
            let sourceFPS = built.frameDuration.seconds > 0 ? 1 / built.frameDuration.seconds : 30
            let fps = min(sourceFPS, video.maxFrameRate ?? sourceFPS)
            interval = sourceFPS > fps + 0.5 ? 1 / fps : 0
            half = 0.5 / sourceFPS

            let format: OSType =
                video.codec.hasAlpha
                ? kCVPixelFormatType_32BGRA
                : tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let compositionOut = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: format, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                ])
            compositionOut.videoComposition = built
            compositionOut.alwaysCopiesSampleData = false

            var properties: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps]
            if !video.codec.isProRes {
                properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
                if let maxBytes = settings.maxBytes {
                    let rate = try bitrate(fitting: maxBytes, seconds: seconds, audioBitrate: audioBitrate)
                    targetBitrate = Int(rate)
                    properties[AVVideoAverageBitRateKey] = Int(rate)
                    // A hard one-second cap too: the average alone overshoots on short clips.
                    properties[kVTCompressionPropertyKey_DataRateLimits as String] = [rate / 8, 1.0]
                } else {
                    properties[AVVideoQualityKey] = min(1, max(0, video.quality))
                }
                if tenBit { properties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
            }
            var output: [String: Any] = [
                AVVideoCodecKey: video.codec.avCodec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect, AVVideoCompressionPropertiesKey: properties,
            ]
            if let hdr = video.hdr {
                output[AVVideoColorPropertiesKey] = [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: hdr == .hlg ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                ]
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw ConvertError(.unsupportedPair, "\(settings.fileType.rawValue) can't hold \(video.codec.rawValue) video.")
            }
            reader.add(compositionOut)
            writer.add(input)
            (videoOut, videoIn) = (compositionOut, input)
        }
        guard videoIn != nil || audioIn != nil else { throw ConvertError(.unsupportedInput, "There's nothing to encode.") }

        try Task.checkCancellation()
        guard reader.startReading() else {
            throw ConvertError(.corruptInput, "Couldn't render the timeline: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        guard writer.startWriting() else {
            throw ConvertError(.internal, "Couldn't start the encoder: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: range.start)

        let start = range.start.seconds
        let (dropInterval, halfFrame) = (interval, half)
        let cancel = UncheckedSendable(reader)
        let watched = UncheckedSendable(writer)
        let videoIO = videoOut.flatMap { out in videoIn.map { UncheckedSendable((out, $0)) } }
        let audioIO = audioOut.flatMap { out in audioIn.map { UncheckedSendable((out, $0)) } }
        let soundOnly = videoIO == nil
        let frames = await withTaskCancellationHandler {
            await withTaskGroup(of: (isVideo: Bool, count: Int).self) { group in
                if let videoIO {
                    group.addTask {
                        let count = await VideoConverter.pump(videoIO, label: "composition.video", writer: watched, reader: cancel) {
                            buffer, state in
                            let pts = buffer.presentationTimeStamp.seconds
                            if dropInterval > 0 {
                                if pts < state.next - halfFrame { return false }
                                state.next = (pts > state.next + dropInterval ? pts : state.next) + dropInterval
                            }
                            if seconds > 0 { progress(min(1, (pts - start) / seconds)) }
                            return true
                        }
                        return (true, count)
                    }
                }
                if let audioIO {
                    group.addTask {
                        let count = await VideoConverter.pump(audioIO, label: "composition.audio", writer: watched, reader: cancel) { buffer, _ in
                            if soundOnly, seconds > 0 { progress(min(1, (buffer.presentationTimeStamp.seconds - start) / seconds)) }
                            return true
                        }
                        return (false, count)
                    }
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
        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw ConvertError(.internal, "The export stopped: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        await writer.finishWriting()
        withExtendedLifetime((videoIn, audioIn)) {}  // the writer doesn't retain its inputs while it finishes
        guard writer.status == .completed else {
            throw ConvertError(.internal, "Couldn't finish the file: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        progress(1)
        return EncodeResult(width: Int(size.width), height: Int(size.height), frames: frames, targetBitrate: targetBitrate)
    }

    private static func even(_ value: Double) -> CGFloat { CGFloat(VideoConverter.even(CGFloat(value))) }
}
