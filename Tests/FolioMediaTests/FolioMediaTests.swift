import AVFoundation
import AppKit
import Testing
import UniformTypeIdentifiers

@testable import FolioMedia

// MARK: - Export settings mapping

@Suite struct ExportSettingsTests {
    @Test func presetsMatchFormats() {
        #expect(ExportFormat.original.preset == AVAssetExportPresetPassthrough)
        #expect(ExportFormat.hevc4K.preset == AVAssetExportPresetHEVC3840x2160)
        #expect(ExportFormat.hevc1080p.preset == AVAssetExportPresetHEVC1920x1080)
        #expect(ExportFormat.h264_720p.preset == AVAssetExportPreset1280x720)
        #expect(ExportFormat.h264_480p.preset == AVAssetExportPreset640x480)
        #expect(ExportFormat.proRes.preset == AVAssetExportPresetAppleProRes422LPCM)
        #expect(ExportFormat.m4a.preset == AVAssetExportPresetAppleM4A)
        #expect(ExportFormat.wav.preset == nil)
    }

    @Test func containers() {
        #expect(ExportFormat.original.fileType(source: .quickTimeMovie) == .mov)
        #expect(ExportFormat.original.fileType(source: .mpeg4Movie) == .mp4)
        #expect(ExportFormat.original.fileType(source: .mpeg4Audio) == .m4a)
        #expect(ExportFormat.original.fileType(source: .wav) == .m4a)
        #expect(ExportFormat.h264_1080p.fileType(source: .quickTimeMovie) == .mp4)
        #expect(ExportFormat.proRes.fileType(source: .mpeg4Movie) == .mov)
        #expect(ExportFormat.wav.fileType(source: .mpeg4Movie) == .wav)
    }

    @Test func audioFilesOnlyOfferAudioFormats() {
        #expect(ExportFormat.available(hasVideo: false) == [.original, .m4a, .wav])
        #expect(ExportFormat.available(hasVideo: true).count == ExportFormat.allCases.count)
    }

    @Test func onlySpeedForcesReencode() {
        var edits = MediaEdits()
        edits.quarterTurns = 1
        edits.flipHorizontal = true
        edits.removeAudio = true
        #expect(!edits.requiresReencode)
        edits.speed = 2
        #expect(edits.requiresReencode)
    }

    @Test func rotationWrapsBothWays() {
        var edits = MediaEdits()
        edits.rotate(clockwise: false)
        #expect(edits.quarterTurns == 3)
        for _ in 0..<5 { edits.rotate(clockwise: true) }
        #expect(edits.quarterTurns == 0)
        #expect(edits.isIdentity)
    }
}

// MARK: - Geometry and time-range math

@Suite struct MediaMathTests {
    let hd = CGSize(width: 1920, height: 1080)

    @Test func quarterTurnSwapsDisplaySize() {
        var edits = MediaEdits()
        edits.quarterTurns = 1
        let t = MediaMath.transform(natural: hd, preferred: .identity, edits: edits)
        #expect(MediaMath.displaySize(natural: hd, transform: t) == CGSize(width: 1080, height: 1920))
        // Anchored at the origin, as AVFoundation expects.
        let box = CGRect(origin: .zero, size: hd).applying(t)
        #expect(box.minX == 0 && box.minY == 0)
        // Clockwise: the top-left corner of the picture ends up top-right.
        #expect(CGPoint.zero.applying(t) == CGPoint(x: 1080, y: 0))
    }

    @Test func rotationComposesWithSourceTransform() {
        // A portrait iPhone clip is stored landscape with a 90° transform; turning it
        // left once more makes it landscape again.
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        var edits = MediaEdits()
        edits.quarterTurns = 3
        let t = MediaMath.transform(natural: hd, preferred: portrait, edits: edits)
        #expect(MediaMath.displaySize(natural: hd, transform: t) == hd)
        #expect(t.a == 1 && t.d == 1 && t.tx == 0 && t.ty == 0)
    }

    @Test func horizontalFlipMirrors() {
        var edits = MediaEdits()
        edits.flipHorizontal = true
        let t = MediaMath.transform(natural: hd, preferred: .identity, edits: edits)
        #expect(CGPoint.zero.applying(t) == CGPoint(x: 1920, y: 0))
        #expect(MediaMath.displaySize(natural: hd, transform: t) == hd)
    }

    @Test func speedScalesDuration() {
        let ten = CMTime(seconds: 10, preferredTimescale: 600)
        #expect(MediaMath.scaled(ten, speed: 2).seconds == 5)
        #expect(MediaMath.scaled(ten, speed: 0.5).seconds == 20)
        #expect(abs(MediaMath.scaled(ten, speed: 1.5).seconds - 6.6667) < 0.001)
        #expect(MediaMath.scaled(ten, speed: 0) == ten)
    }

    @Test func clampOrdersAndBoundsRanges() {
        let d = CMTime(seconds: 10, preferredTimescale: 600)
        let r = MediaMath.clamp(
            from: CMTime(seconds: 12, preferredTimescale: 600), to: CMTime(seconds: 4, preferredTimescale: 600), within: d)
        #expect(r?.start.seconds == 4 && r?.end.seconds == 10)
        #expect(MediaMath.clamp(CMTimeRange(start: d, end: d), to: d) == nil)
    }

    @Test func inAndOutPoints() {
        let d = CMTime(seconds: 10, preferredTimescale: 600)
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
        let a = MediaMath.settingPoint(t(2), isIn: true, current: nil, duration: d)
        #expect(a?.start.seconds == 2 && a?.end.seconds == 10)
        let b = MediaMath.settingPoint(t(6), isIn: false, current: a, duration: d)
        #expect(b?.start.seconds == 2 && b?.end.seconds == 6)
        // An in point after the out point starts a new range to the end, never an inverted one.
        let c = MediaMath.settingPoint(t(8), isIn: true, current: b, duration: d)
        #expect(c?.start.seconds == 8 && c?.end.seconds == 10)
        // An out point before the in point starts a new range from zero.
        let e = MediaMath.settingPoint(t(1), isIn: false, current: c, duration: d)
        #expect(e?.start.seconds == 0 && e?.end.seconds == 1)
    }

    @Test func timecodes() {
        #expect(MediaMath.timecode(CMTime(seconds: 3.25, preferredTimescale: 600)) == "0:03.25")
        #expect(MediaMath.timecode(CMTime(seconds: 125.5, preferredTimescale: 600)) == "2:05.50")
        #expect(MediaMath.timecode(CMTime(seconds: 3723, preferredTimescale: 600)) == "1:02:03.00")
        #expect(MediaMath.timecode(.invalid) == "--:--")
    }
}

// MARK: - Waveform downsampling

@Suite struct WaveformTests {
    @Test func peaksPerBin() {
        let samples: [Float] = [0.1, -0.9, 0.2, 0.3, -0.4, 0.5, 0, 0]
        #expect(PeakAccumulator.downsample(samples, bins: 4) == [0.9, 0.3, 0.5, 0])
    }

    @Test func clipsAndHandlesMoreBinsThanSamples() {
        let peaks = PeakAccumulator.downsample([2, -0.5], bins: 4)
        #expect(peaks == [1, 0, 0.5, 0])
    }

    @Test func streamingMatchesBatch() {
        let samples = (0..<10_000).map { Float(sin(Double($0) * 0.01)) }
        var acc = PeakAccumulator(expectedSamples: samples.count, bins: 100)
        for chunk in stride(from: 0, to: samples.count, by: 777) {
            let part = Array(samples[chunk..<min(chunk + 777, samples.count)])
            part.withUnsafeBufferPointer { acc.add($0) }
        }
        #expect(acc.peaks == PeakAccumulator.downsample(samples, bins: 100))
    }

    @Test func readsRealAudio() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let peaks = try await Waveform.compute(try TestMedia.tone(in: folder, amplitude: 0.5))
        #expect(peaks.count == Waveform.bins)
        let loudest = peaks.max() ?? 0
        #expect(loudest > 0.4 && loudest < 0.6)
        #expect(peaks.filter { $0 > 0.3 }.count > Waveform.bins * 9 / 10)
    }
}

// MARK: - GIF timing

@Suite struct GIFTimingTests {
    @Test func delaysAddUpToTheDuration() {
        let frames = GIFTiming.frames(duration: 2, fps: 15, maxFrames: 1000)
        #expect(frames.count == 30)
        let total = frames.map(\.delay).reduce(0, +)
        #expect(abs(total - 2) < 0.0001)
        // 1/15 s is 6.67 cs: delays alternate between 6 and 7, never drift.
        #expect(Set(frames.map { Int(($0.delay * 100).rounded()) }).isSubset(of: [6, 7]))
        #expect(frames[1].time == 2.0 / 30)
    }

    @Test func capSpreadsFramesOverTheRange() {
        let frames = GIFTiming.frames(duration: 100, fps: 10, maxFrames: 50)
        #expect(frames.count == 50)
        #expect(frames.last?.time == 98)
        #expect(abs(frames.map(\.delay).reduce(0, +) - 100) < 0.0001)
    }

    @Test func neverBelowTwoCentiseconds() {
        #expect(GIFTiming.frames(duration: 1, fps: 100, maxFrames: 1000).allSatisfy { $0.delay >= 0.02 })
        #expect(GIFTiming.frames(duration: 0, fps: 10, maxFrames: 10).isEmpty)
    }
}

// MARK: - Info and keyboard

@Suite struct InfoAndKeysTests {
    @Test func codecNames() {
        #expect(MediaInfo.codecName(kCMVideoCodecType_HEVC) == "HEVC")
        #expect(MediaInfo.codecName(kAudioFormatMPEG4AAC) == "AAC")
        #expect(MediaInfo.codecName(0x7A7A7A7A) == "zzzz")
        #expect(MediaInfo.fourCCString(0x0000_0001) == "0x00000001")
    }

    @Test func locations() {
        #expect(MediaInfo.formatLocation(iso6709: "+37.3318-122.0312+010.000/") == "37.3318° N, 122.0312° W")
        #expect(MediaInfo.formatLocation(iso6709: "-33.8688+151.2093/") == "33.8688° S, 151.2093° E")
        #expect(MediaInfo.formatLocation(iso6709: "garbage") == nil)
    }

    @Test func numberFormats() {
        #expect(InfoFormat.bitrate(12_400_000) == "12.4 Mb/s")
        #expect(InfoFormat.bitrate(128_000) == "128 kb/s")
        #expect(InfoFormat.frameRate(30) == "30 fps")
        #expect(InfoFormat.frameRate(29.97) == "29.97 fps")
        #expect(InfoFormat.frameRate(23.976) == "23.98 fps")
        #expect(InfoFormat.sampleRate(48_000) == "48 kHz")
        #expect(InfoFormat.sampleRate(44_100) == "44.1 kHz")
        #expect(InfoFormat.channels(2) == "Stereo")
        #expect(InfoFormat.speed(1.5) == "1.5×")
        #expect(InfoFormat.speed(2) == "2×")
    }

    @Test func shuttleRates() {
        #expect(Shuttle.rate(after: .forward, current: 0, canReverse: true) == 1)
        #expect(Shuttle.rate(after: .forward, current: 1, canReverse: true) == 2)
        #expect(Shuttle.rate(after: .forward, current: 8, canReverse: true) == 8)
        #expect(Shuttle.rate(after: .forward, current: -4, canReverse: true) == 1)
        #expect(Shuttle.rate(after: .reverse, current: 2, canReverse: true) == -1)
        #expect(Shuttle.rate(after: .reverse, current: -1, canReverse: true) == -2)
        #expect(Shuttle.rate(after: .reverse, current: 1, canReverse: false) == 0)
        #expect(Shuttle.rate(after: .pause, current: 4, canReverse: true) == 0)
    }

    @Test func keyMap() {
        #expect(PlayerKey.action(characters: " ", modifiers: []) == .playPause)
        #expect(PlayerKey.action(characters: "L", modifiers: [.shift]) == .shuttle(.forward))
        #expect(PlayerKey.action(characters: "i", modifiers: []) == .markIn)
        let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey)).map(Character.init) ?? " ")
        #expect(PlayerKey.action(characters: right, modifiers: [.numericPad, .function]) == .step(1))
        #expect(PlayerKey.action(characters: "t", modifiers: [.command]) == nil)
        #expect(PlayerKey.action(characters: "x", modifiers: []) == nil)
    }
}

// MARK: - End to end, on generated media

@Suite struct ExportIntegrationTests {
    @Test func passthroughTrimKeepsTheRange() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await TestMedia.video(in: folder)
        let out = folder.appending(path: "trim.mov")
        let range = CMTimeRange(start: CMTime(value: 15, timescale: 30), end: CMTime(value: 45, timescale: 30))
        try await MediaExport.run(ExportRequest(source: source, format: .original, range: range), to: out) { _ in }
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(duration - 1) < 0.05)
        // Passthrough: same codec, not re-encoded.
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.formatDescriptions).first?.mediaSubType.rawValue == kCMVideoCodecType_H264)
    }

    @Test func rotationIsLosslessAndChangesDisplaySize() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await TestMedia.video(in: folder, seconds: 0.5)
        let out = folder.appending(path: "rotated.mov")
        var edits = MediaEdits()
        edits.quarterTurns = 1
        try await MediaExport.run(ExportRequest(source: source, format: .original, edits: edits), to: out) { _ in }
        let info = try await MediaInfo.load(out)
        #expect(info.video?.size == CGSize(width: 64, height: 128))
        #expect(info.video?.codec == "H.264")
    }

    @Test func doubleSpeedHalvesDuration() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await TestMedia.video(in: folder, seconds: 2)
        let out = folder.appending(path: "fast.mov")
        var edits = MediaEdits()
        edits.speed = 2
        try await MediaExport.run(ExportRequest(source: source, format: .original, edits: edits), to: out) { _ in }
        #expect(abs(try await AVURLAsset(url: out).load(.duration).seconds - 1) < 0.1)
    }

    @Test func wavExportOfASelection() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try TestMedia.tone(in: folder, seconds: 1)
        let out = folder.appending(path: "part.wav")
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 44_100))
        let progress = ProgressBox()
        try await MediaExport.run(ExportRequest(source: source, format: .wav, range: range), to: out) { progress.last = $0 }
        let file = try AVAudioFile(forReading: out)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 0.5) < 0.01)
        #expect(progress.last == 1)
    }

    @Test func m4aFromAudio() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appending(path: "tone.m4a")
        try await MediaExport.run(ExportRequest(source: try TestMedia.tone(in: folder), format: .m4a), to: out) { _ in }
        #expect(try await MediaInfo.load(out).audio?.codec == "AAC")
    }

    @Test func audioOnlyExportOfSilentVideoExplainsWhy() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await TestMedia.video(in: folder, seconds: 0.5)
        await #expect(throws: (any Error).self) {
            try await MediaExport.run(ExportRequest(source: source, format: .m4a), to: folder.appending(path: "x.m4a")) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "x.m4a").path))
    }

    @Test func gifHasOneFramePerTick() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await TestMedia.video(in: folder, seconds: 1)
        let out = folder.appending(path: "clip.gif")
        try await GIFMaker.make(from: source, range: nil, fps: 10, width: 64, to: out) { _ in }
        let image = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetCount(image) == 10)
        let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect((gif?[kCGImagePropertyGIFDelayTime] as? Double).map { abs($0 - 0.1) < 0.001 } == true)
        #expect(CGImageSourceCopyPropertiesAtIndex(image, 0, nil).map { ($0 as NSDictionary)[kCGImagePropertyPixelWidth] as? Int } == 64)
    }

    @Test func stillFrameIsFullResolution() async throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await TestMedia.video(in: folder, seconds: 1)
        let image = try await Frames.still(source, at: CMTime(value: 7, timescale: 30))
        #expect(image.width == 128 && image.height == 64)
        let png = folder.appending(path: "frame.png")
        try Frames.writePNG(image, to: png)
        #expect(FileManager.default.fileExists(atPath: png.path))
    }

    @Test func toolsHaveMediaIDs() {
        #expect(MediaTools.all.map(\.id) == ["media.extractAudio", "media.convertMP4", "media.compress", "media.makeGIF"])
    }
}

/// Collects the last progress value from a @Sendable callback.
nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    var last: Double {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
