import AVFoundation  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import FolioConvert
import FolioKit
import ImageIO
import Synchronization
import Testing

@testable import FolioMedia

/// A generated clip and a tone as one composition with a video composition and an audio
/// mix: what the render engine hands the exporter.
nonisolated private func timeline(in folder: URL, seconds: Double = 2, width: Int = 128, height: Int = 64) async throws -> TimelineMovie {
    let video = AVURLAsset(url: try await TestMedia.video(in: folder, seconds: seconds, width: width, height: height))
    let sound = AVURLAsset(url: try TestMedia.tone(in: folder, seconds: seconds))
    let composition = AVMutableComposition()
    let range = CMTimeRange(start: .zero, duration: try await video.load(.duration))
    try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(range, of: try await video.loadTracks(withMediaType: .video)[0], at: .zero)
    let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try audio.insertTimeRange(range, of: try await sound.loadTracks(withMediaType: .audio)[0], at: .zero)
    let parameters = AVMutableAudioMixInputParameters(track: audio)
    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 2)))
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameters]
    let videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: composition)
    return TimelineMovie(asset: composition, videoComposition: videoComposition, audioMix: mix)
}

nonisolated private func size(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? .max
}

nonisolated private func ms(_ value: Int64) -> Time { Time(value: value, timescale: 1000) }

nonisolated private func cue(_ start: Int64, _ end: Int64, _ text: String) -> SubtitleCue {
    SubtitleCue(range: TimeRange(start: ms(start), end: ms(end)), text: text)
}

@Suite("Timeline export", .timeLimit(.minutes(1)))
struct TimelineExportTests {
    // MARK: Caption files

    @Test func srtAndVTTRoundTrip() throws {
        let cues = [cue(1500, 3250, "Hello, world."), cue(3_723_004, 3_725_000, "Two\nlines & <tags>")]
        let srt = CaptionFiles.srt(cues)
        #expect(srt.hasPrefix("1\n00:00:01,500 --> 00:00:03,250\nHello, world.\n"))
        #expect(srt.contains("2\n01:02:03,004 --> 01:02:05,000\nTwo\nlines & <tags>"))
        #expect(try CaptionFiles.parse(srt) == cues)

        let vtt = CaptionFiles.vtt(cues)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:03.250\n"))
        #expect(vtt.contains("lines &amp; &lt;tags&gt;"))
        #expect(try CaptionFiles.parse(vtt) == cues)
    }

    @Test func parsesRealWorldVTT() throws {
        let text = "\u{FEFF}WEBVTT - made elsewhere\r\n\r\nNOTE a comment --> not a cue\r\n\r\nintro\r\n00:01.000 --> 00:02.500 align:start line:90%\r\nShort times\r\n\r\n00:00:03.000 --> 00:00:04.000\r\nLast\r\n"
        #expect(try CaptionFiles.parse(text) == [cue(1000, 2500, "Short times"), cue(3000, 4000, "Last")])
        #expect(throws: FolioError.self) { try CaptionFiles.parse("1\n00:00:xx,000 --> 00:00:02,000\nBad\n") }
    }

    @Test func assExport() {
        let ass = CaptionFiles.ass([cue(1500, 2250, "One\nTwo")], canvas: CanvasSize(width: 1920, height: 1080))
        #expect(ass.hasPrefix("[Script Info]\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080"))
        #expect(ass.contains("Style: Default,Helvetica,54,"))
        #expect(ass.contains("Dialogue: 0,0:00:01.50,0:00:02.25,Default,,0,0,0,,One\\NTwo"))
    }

    @Test func projectGivesSubtitlesAndChapters() throws {
        var project = Project()
        var captions = CaptionTrack()
        captions.language = "fr-FR"
        captions.burnIn = false
        captions.cues = [cue(0, 1000, "Bonjour").captionCue]
        project.captions = [captions]
        project.markers = [
            Marker(time: .zero, name: "Intro", kind: .chapter), Marker(time: ms(500), name: "todo", kind: .todo),
            Marker(time: ms(1000), kind: .chapter),
        ]
        let movie = TimelineMovie(asset: AVMutableComposition(), videoComposition: nil, audioMix: nil, project: project)
        #expect(movie.subtitles == [cue(0, 1000, "Bonjour")])
        #expect(movie.subtitleLanguage == "fr-FR")
        #expect(movie.chapters == [Chapter(start: .zero, title: "Intro"), Chapter(start: ms(1000), title: "Chapter 2")])

        project.captions[0].burnIn = true
        #expect(TimelineMovie(asset: AVMutableComposition(), videoComposition: nil, audioMix: nil, project: project).subtitles.isEmpty)
    }

    @Test func gapsBetweenCuesGetEmptySamples() {
        let spans = SubtitleMux.filled([("a", TimeRange(start: ms(500), end: ms(1000)))], until: ms(2000))
        #expect(spans.map(\.0) == ["", "a", ""])
        #expect(spans.map(\.1.end) == [ms(500), ms(1000), ms(2000)])
    }

    // MARK: Presets

    @Test func deliveryPresetsNeverUpscale() {
        let hd = CGSize(width: 1280, height: 720)
        #expect(DeliveryPreset.fit(hd, into: (1920, 1080)) == (1280, 720))
        #expect(DeliveryPreset.fit(CGSize(width: 3840, height: 2160), into: (1920, 1080)) == (1920, 1080))
        #expect(DeliveryPreset.fit(CGSize(width: 1920, height: 1080), into: (1080, 1920)) == (1080, 608))
        for preset in DeliveryPreset.allCases {
            if case .encode(let settings) = preset.job(renderSize: hd), let video = settings.video {
                #expect((video.width ?? 0) <= 1280 && (video.height ?? 0) <= 720, "\(preset)")
            }
        }
        #expect(DeliveryPreset.vertical.aspect == .vertical)
        #expect(DeliveryPreset.proResMaster.job(renderSize: hd) == .preset(.proRes))
        #expect(DeliveryPreset.gif.job(renderSize: hd) == .gif(fps: 15, width: 480))
        #expect(TimelineExportJob.preset(.wav).fileExtension == "wav")
        #expect(TimelineExportJob.gif(fps: 10, width: 64).fileExtension == "gif")
    }

    @Test func everyExportFormatWorksFromATimeline() async throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await timeline(in: dir)
        for format in ExportFormat.allCases {
            let job = TimelineExportJob.preset(format)
            let out = dir.appending(path: "\(format.rawValue).\(job.fileExtension)")
            try await TimelineExport.run(movie, job: job, to: out)
            let asset = AVURLAsset(url: out)
            #expect(try await asset.loadTracks(withMediaType: .video).isEmpty == format.isAudioOnly, "\(format)")
            #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty, "\(format)")
            #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1, "\(format)")
        }
    }

    @Test func socialPresetEndToEnd() async throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await timeline(in: dir, width: 108, height: 192)
        let job = DeliveryPreset.vertical.job(renderSize: CGSize(width: 108, height: 192))
        let out = dir.appending(path: "reel.\(job.fileExtension)")
        try await TimelineExport.run(movie, job: job, to: out)
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        #expect(try await track.load(.naturalSize) == CGSize(width: 108, height: 192))
    }

    // MARK: Subtitles, chapters and compress to size

    @Test func softSubtitlesAndChaptersAfterCompressToSize() async throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var movie = try await timeline(in: dir)
        movie.subtitles = [cue(0, 900, "Welcome to Folio."), cue(1000, 2000, "Automatic captions.")]
        movie.subtitleLanguage = "en-US"
        movie.chapters = [Chapter(start: .zero, title: "Intro"), Chapter(start: ms(1000), title: "Second half")]
        let budget: Int64 = 150_000
        let out = dir.appending(path: "final.mp4")
        try await TimelineExport.run(movie, job: .encode(EncodeSettings(audio: .aac(bitrate: 64_000), maxBytes: budget)), to: out)
        #expect(size(out) <= budget * 105 / 100)

        let asset = AVURLAsset(url: out)
        #expect(try await asset.loadTracks(withMediaType: .subtitle).count == 1)
        let legible = try #require(try await asset.loadMediaSelectionGroup(for: .legible))
        #expect(legible.options.contains { $0.extendedLanguageTag == "en-US" })
        let locales = try await asset.load(.availableChapterLocales)
        let locale = try #require(locales.first)
        let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])
        var titles: [String] = []
        for group in groups { titles.append(try await group.items.first?.load(.stringValue) ?? "") }
        #expect(titles == ["Intro", "Second half"])
        #expect(groups.map { $0.timeRange.start.seconds } == [0, 1])
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["video.mov", "tone.wav", "final.mp4"])
    }

    // MARK: Cancellation, stills, GIFs

    @Test func cancellingLeavesNoFileAndKeepsTheOldOne() async throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await timeline(in: dir, seconds: 4, width: 1280, height: 720)
        let fresh = dir.appending(path: "fresh.mp4")
        let existing = dir.appending(path: "existing.mp4")
        try Data("keep me".utf8).write(to: existing)
        for out in [fresh, existing] {
            let handle = Mutex<Task<Void, any Error>?>(nil)
            let task = Task {
                try await TimelineExport.run(movie, job: .encode(EncodeSettings()), to: out) { fraction in
                    if fraction > 0.05 { handle.withLock { $0?.cancel() } }
                }
            }
            handle.withLock { $0 = task }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
    }

    @Test func stillAndGIFFromAComposition() async throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await timeline(in: dir)
        let still = try await TimelineExport.still(movie, at: CMTime(value: 1, timescale: 1))
        #expect(still.width == 128 && still.height == 64)

        let png = dir.appending(path: "frame.png")
        try await TimelineExport.run(movie, job: .still(at: .zero), to: png)
        #expect(FileManager.default.fileExists(atPath: png.path))

        let gif = dir.appending(path: "clip.gif")
        try await TimelineExport.run(movie, job: .gif(fps: 10, width: 64), to: gif)
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 20)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyPixelWidth] as? Int == 64)
    }

    // MARK: Lossless concat

    @Test func concatenatesMatchingClipsWithoutReencoding() async throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await TestMedia.video(in: try TestMedia.folder())
        let b = try await TestMedia.video(in: try TestMedia.folder())
        let odd = try await TestMedia.video(in: try TestMedia.folder(), width: 64, height: 64)
        defer { for url in [a, b, odd] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }

        #expect(try await TimelineExport.canConcatenateLosslessly([a, b]))
        #expect(try await !TimelineExport.canConcatenateLosslessly([a, odd]))
        let out = dir.appending(path: "joined.mov")
        try await TimelineExport.concatenate([a, b], to: out)
        let asset = AVURLAsset(url: out)
        #expect(abs(try await asset.load(.duration).seconds - 4) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let formats = try await track.load(.formatDescriptions)
        #expect(formats.count == 1 && CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264)

        // Copied, not re-encoded: the parameter sets are the source's own.
        let source = try await AVURLAsset(url: a).loadTracks(withMediaType: .video)[0].load(.formatDescriptions)[0]
        #expect(CMFormatDescriptionEqual(formats[0], otherFormatDescription: source))

        await #expect(throws: FolioError.self) { try await TimelineExport.concatenate([a, odd], to: dir.appending(path: "no.mov")) }
    }
}
