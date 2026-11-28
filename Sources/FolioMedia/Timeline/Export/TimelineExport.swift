import AVFoundation
import FolioConvert
import FolioKit
import ImageIO
import UniformTypeIdentifiers

/// What an export renders: the render engine's composition, video composition and audio
/// mix, plus the overlays the mux step adds. AVFoundation's composition classes aren't
/// annotated Sendable; an export only reads them.
nonisolated struct TimelineMovie: @unchecked Sendable {
    var asset: AVAsset
    var videoComposition: AVVideoComposition?
    var audioMix: AVAudioMix?
    /// `nil` exports everything.
    var timeRange: CMTimeRange?
    /// Soft subtitles; empty for none.
    var subtitles: [SubtitleCue] = []
    var subtitleLanguage = "en-US"
    var chapters: [Chapter] = []

    init(asset: AVAsset, videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil, timeRange: CMTimeRange? = nil) {
        self.asset = asset
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.timeRange = timeRange
    }

    /// Chapters from the project's chapter markers, and soft subtitles from its first enabled
    /// caption track that isn't burned in (a burned-in one is already in the picture).
    init(asset: AVAsset, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?, project: Project) {
        self.init(asset: asset, videoComposition: videoComposition, audioMix: audioMix)
        chapters = project.exportChapters
        if let track = project.captions.first(where: { $0.isEnabled && !$0.burnIn }) {
            subtitles = project.subtitleCues(track)
            subtitleLanguage = track.language
        }
    }
}

/// How to export.
nonisolated enum TimelineExportJob: Sendable, Equatable {
    /// An `AVAssetExportSession` preset (the Export menu's formats).
    case preset(ExportFormat)
    /// The FolioConvert encoder: constant quality, compress to size, fps cap, 10-bit/HDR, alpha.
    case encode(EncodeSettings)
    case gif(fps: Double, width: Int)
    /// One PNG frame, at this timeline time.
    case still(at: CMTime)

    var fileType: AVFileType {
        switch self {
        case .preset(let format): format == .original ? .mov : format.fileType(source: nil)
        case .encode(let settings): settings.fileType
        case .gif: AVFileType(UTType.gif.identifier)
        case .still: AVFileType(UTType.png.identifier)
        }
    }

    /// The extension a save panel should use.
    var fileExtension: String { UTType(fileType.rawValue)?.preferredFilenameExtension ?? "mov" }
}

/// One-click delivery targets. Presets never upscale: a 1080p preset on a 720p canvas
/// exports 720p. Set the canvas to `aspect` first, or the picture is fitted into the box.
nonisolated enum DeliveryPreset: String, CaseIterable, Identifiable, Sendable {
    case youTube4K, youTube1080p
    /// Instagram Reels, TikTok, YouTube Shorts.
    case vertical
    case square
    /// Instagram feed, 4:5.
    case portrait
    case x
    case gif
    case audioOnly
    case proResMaster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youTube4K: "YouTube 4K"
        case .youTube1080p: "YouTube 1080p"
        case .vertical: "Reels, TikTok, Shorts (9:16)"
        case .square: "Instagram square (1:1)"
        case .portrait: "Instagram portrait (4:5)"
        case .x: "X (16:9)"
        case .gif: "GIF"
        case .audioOnly: "Audio only (M4A)"
        case .proResMaster: "ProRes 422 master"
        }
    }

    /// The canvas shape the preset is made for, if it has one.
    var aspect: AspectPreset? {
        switch self {
        case .youTube4K, .youTube1080p, .x: .widescreen
        case .vertical: .vertical
        case .square: .square
        case .portrait: .portrait
        case .gif, .audioOnly, .proResMaster: nil
        }
    }

    /// The largest frame it allows.
    private var box: (width: Int, height: Int)? {
        switch self {
        case .youTube4K: (3840, 2160)
        case .youTube1080p, .x: (1920, 1080)
        case .vertical: (1080, 1920)
        case .square: (1080, 1080)
        case .portrait: (1080, 1350)
        case .gif, .audioOnly, .proResMaster: nil
        }
    }

    func job(renderSize: CGSize) -> TimelineExportJob {
        switch self {
        case .gif: return .gif(fps: 15, width: min(480, Int(renderSize.width)))
        case .audioOnly: return .preset(.m4a)
        case .proResMaster: return .preset(.proRes)
        default: break
        }
        let (w, h) = box.map { Self.fit(renderSize, into: $0) } ?? (Int(renderSize.width), Int(renderSize.height))
        // HEVC where the site re-encodes from a high-quality upload; H.264 where uploads must play everywhere.
        let codec: EncodeSettings.Codec = self == .youTube4K ? .hevc : .h264
        let video = EncodeSettings.Video(codec: codec, width: w, height: h, maxFrameRate: 60, quality: 0.65)
        return .encode(EncodeSettings(video: video, audio: .aac(bitrate: 256_000), fileType: .mp4))
    }

    /// `size` scaled down (never up) to fit the box, even-sided.
    static func fit(_ size: CGSize, into box: (width: Int, height: Int)) -> (Int, Int) {
        let scale = min(1, Double(box.width) / max(1, size.width), Double(box.height) / max(1, size.height))
        let even = { (v: Double) in max(2, Int((v * scale / 2).rounded()) * 2) }
        return (even(size.width), even(size.height))
    }
}

/// Exports a timeline. Every path writes through `MediaExport.writeAtomically`, so a
/// cancelled or failed export leaves no file and never replaces an existing one.
nonisolated enum TimelineExport {
    private static let log = Log.make("TimelineExport")

    /// Runs `job`, then adds soft subtitles and chapters when the movie has any and the
    /// container is a movie. Progress runs 0…1 across both steps.
    static func run(
        _ movie: TimelineMovie, job: TimelineExportJob, to destination: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let type = job.fileType
        let mux = (!movie.subtitles.isEmpty || !movie.chapters.isEmpty) && [.mp4, .mov, .m4v].contains(type) && hasVideo(job)
        try await MediaExport.writeAtomically(to: destination) { temp in
            let render = mux ? temp.deletingLastPathComponent().appending(path: "render-" + temp.lastPathComponent) : temp
            let share = mux ? 0.95 : 1
            try await write(movie, job: job, to: render) { progress($0 * share) }
            if mux {
                try await SubtitleMux.mux(
                    render, subtitles: movie.subtitles, language: movie.subtitleLanguage, chapters: movie.chapters, to: temp, fileType: type)
                progress(1)
            }
        }
        log.info("Exported a timeline to \(destination.lastPathComponent, privacy: .private)")
    }

    private static func hasVideo(_ job: TimelineExportJob) -> Bool {
        switch job {
        case .preset(let format): !format.isAudioOnly
        case .encode(let settings): settings.video != nil
        case .gif, .still: false
        }
    }

    private static func write(_ movie: TimelineMovie, job: TimelineExportJob, to url: URL, progress: @escaping @Sendable (Double) -> Void)
        async throws
    {
        switch job {
        case .preset(.wav):
            let settings = EncodeSettings(video: nil, audio: .pcm, fileType: .wav)
            _ = try await encode(movie, settings, url, progress)
        case .preset(let format):
            try await exportSession(movie, format: format, to: url, progress: progress)
        case .encode(let settings):
            _ = try await encode(movie, settings, url, progress)
        case .gif(let fps, let width):
            try await gif(movie, fps: fps, width: width, to: url, progress: progress)
        case .still(let time):
            try Frames.writePNG(try await still(movie, at: time), to: url)
            progress(1)
        }
    }

    private static func encode(_ movie: TimelineMovie, _ settings: EncodeSettings, _ url: URL, _ progress: @escaping @Sendable (Double) -> Void)
        async throws -> EncodeResult
    {
        do {
            return try await CompositionEncoder.encode(
                movie.asset, videoComposition: movie.videoComposition, audioMix: movie.audioMix, timeRange: movie.timeRange,
                settings: settings, to: url, progress: progress)
        } catch let error as ConvertError {
            throw FolioError(error.hint.map { "\(error.message) \($0)" } ?? error.message)
        }
    }

    private static func exportSession(
        _ movie: TimelineMovie, format: ExportFormat, to url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Passthrough can't render a video composition, so "original" means the best re-encode here.
        let preset = format == .original ? AVAssetExportPresetHighestQuality : format.preset ?? AVAssetExportPresetHighestQuality
        let type = TimelineExportJob.preset(format).fileType
        guard let session = AVAssetExportSession(asset: movie.asset, presetName: preset),
            await AVAssetExportSession.compatibility(ofExportPreset: preset, with: movie.asset, outputFileType: type)
        else {
            throw FolioError("This timeline can't be exported as \(format.title).")
        }
        if !format.isAudioOnly { session.videoComposition = movie.videoComposition }
        session.audioMix = movie.audioMix
        if let range = movie.timeRange { session.timeRange = range }
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true
        let observed = UncheckedSendable(session)
        let watcher = Task {
            for await state in observed.value.states(updateInterval: 0.1) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: url, as: type)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FolioError("The export didn't finish: \(error.localizedDescription)")
        }
        progress(1)
    }

    // MARK: Stills and GIFs

    private static func generator(_ movie: TimelineMovie) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: movie.asset)
        generator.videoComposition = movie.videoComposition
        generator.appliesPreferredTrackTransform = true
        return generator
    }

    /// The exact rendered frame at `time`, at the render size.
    static func still(_ movie: TimelineMovie, at time: CMTime) async throws -> CGImage {
        let generator = generator(movie)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            return try await generator.image(at: time).image
        } catch {
            throw FolioError("Couldn't render the frame at \(MediaMath.timecode(time)): \(error.localizedDescription)")
        }
    }

    /// An animated GIF of the timeline (or `movie.timeRange`), timed like `GIFMaker`.
    private static func gif(_ movie: TimelineMovie, fps: Double, width: Int, to url: URL, progress: @escaping @Sendable (Double) -> Void)
        async throws
    {
        let duration = try await movie.asset.load(.duration)
        let span = movie.timeRange ?? CMTimeRange(start: .zero, duration: duration)
        let plan = GIFTiming.frames(duration: span.duration.seconds, fps: fps, maxFrames: GIFMaker.maxFrames)
        guard !plan.isEmpty else { throw FolioError("The timeline is too short to make a GIF.") }
        let generator = generator(movie)
        generator.maximumSize = CGSize(width: width, height: width * 4)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, plan.count, nil) else {
            throw FolioError("Couldn't create “\(url.lastPathComponent)”.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let times = plan.map { span.start + CMTime(seconds: $0.time, preferredTimescale: 600) }
        // Hold early arrivals so frames always go in in order.
        var pending: [Int: CGImage] = [:]
        var next = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard let index = times.firstIndex(of: result.requestedTime) else { continue }
            pending[index] = try result.image
            while let image = pending.removeValue(forKey: next) {
                let delay = plan[next].delay
                let frame = [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: frame] as CFDictionary)
                next += 1
                progress(Double(next) / Double(plan.count))
            }
        }
        guard next == plan.count, CGImageDestinationFinalize(destination) else { throw FolioError("Couldn't write the GIF.") }
    }

    // MARK: Lossless concatenation

    /// Whether `urls` can be joined without re-encoding: the same video codec and frame size,
    /// and the same sound format (or no sound in any of them).
    static func canConcatenateLosslessly(_ urls: [URL]) async throws -> Bool {
        guard urls.count > 1 else { return false }
        var first: Signature?
        for url in urls {
            let signature = try await Signature(AVURLAsset(url: url))
            if first == nil { first = signature } else if signature != first { return false }
        }
        return first?.video != nil
    }

    /// Joins `urls` end to end by copying their samples: no re-encode, as fast as copying.
    /// Throws when the formats differ; re-encode through a timeline then.
    static func concatenate(_ urls: [URL], to destination: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard try await canConcatenateLosslessly(urls) else {
            throw FolioError("These clips have different formats, so they can't be joined without re-encoding.")
        }
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        var audio: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        for (i, url) in urls.enumerated() {
            let asset = AVURLAsset(url: url)
            let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                try video?.insertTimeRange(range, of: track, at: cursor)
                if i == 0 { video?.preferredTransform = try await track.load(.preferredTransform) }
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                audio = audio ?? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try audio?.insertTimeRange(range, of: track, at: cursor)
            }
            cursor = cursor + range.duration
        }
        let type: AVFileType = destination.pathExtension.lowercased() == "mp4" ? .mp4 : destination.pathExtension.lowercased() == "m4v" ? .m4v : .mov
        try await MediaExport.writeAtomically(to: destination) { temp in
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw FolioError("Couldn't start joining the clips.")
            }
            let observed = UncheckedSendable(session)
            let watcher = Task {
                for await state in observed.value.states(updateInterval: 0.1) {
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
            }
            defer { watcher.cancel() }
            try await session.export(to: temp, as: type)
            progress(1)
        }
    }

    /// The parts of a file's format that must match for a sample-copy join.
    private struct Signature: Equatable {
        var video: FourCharCode?
        var size: CGSize = .zero
        var audio: FourCharCode?
        var sampleRate: Double = 0
        var channels: UInt32 = 0

        init(_ asset: AVURLAsset) async throws {
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (formats, size) = try await track.load(.formatDescriptions, .naturalSize)
                video = formats.first.map(CMFormatDescriptionGetMediaSubType)
                self.size = size
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let format = try await track.load(.formatDescriptions).first
                audio = format.map(CMFormatDescriptionGetMediaSubType)
                let asbd = format?.audioStreamBasicDescription
                sampleRate = asbd?.mSampleRate ?? 0
                channels = asbd?.mChannelsPerFrame ?? 0
            }
        }
    }
}
