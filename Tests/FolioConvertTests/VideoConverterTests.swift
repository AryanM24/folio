import AVFoundation  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import Synchronization
import Testing

@testable import FolioConvert

extension Fixture {
    /// An H.264 clip with an AAC track: frames drawn into pixel buffers, sound from `tone`,
    /// muxed by passthrough into a .mov.
    static func clip(_ url: URL, seconds: Double, width: Int = 640, height: Int = 360, fps: Int32 = 30, audio: Bool = true) async throws {
        let scratch = url.deletingLastPathComponent().appending(path: ".fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let silent = audio ? scratch.appending(path: "video.mov") : url

        let writer = try AVAssetWriter(outputURL: silent, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(width * height * Int(fps)) * 0.15)],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            draw(buffer!, frame: frame)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        guard audio else { return }

        let sound = scratch.appending(path: "sound.m4a")
        try tone(sound, seconds: seconds + 0.5, settings: aac)
        let video = AVURLAsset(url: silent), music = AVURLAsset(url: sound)
        let range = CMTimeRange(start: .zero, duration: try await video.load(.duration))
        let composition = AVMutableComposition()
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: try await video.loadTracks(withMediaType: .video)[0], at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: try await music.loadTracks(withMediaType: .audio)[0], at: .zero)
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await session.export(to: url, as: .mov)
    }

    /// A gradient with a bar that moves every frame, so the encoder has motion to code.
    static func draw(_ buffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bar = (frame * 8) % width
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            let shade = UInt32((y * 255 / height + frame) % 256)
            row.update(repeating: 0xFF00_0000 | shade << 16 | UInt32(frame % 256) << 8 | (255 - shade), count: width)
            row.advanced(by: bar).update(repeating: 0xFFFF_FFFF, count: min(40, width - bar))
        }
    }
}

@Suite("Video", .timeLimit(.minutes(1)))
struct VideoConverterTests {
    @Test("Targets: containers, extract audio, GIF; lossless only for container changes and audio")
    func targets() {
        let mov = VideoConverter.targets(from: .mov)
        #expect(Set(mov.map(\.to)) == [.mov, .mp4, .m4v, .m4a, .wav, .gif])
        #expect(mov.first { $0.to == .mp4 }?.losslessAvailable == true)
        #expect(mov.first { $0.to == .mov }?.losslessAvailable == false)
        #expect(mov.first { $0.to == .gif }?.losslessAvailable == false)
    }

    @Test("mov → mp4 remuxes losslessly, verified by hashing every sample")
    func remux() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "clip.mov")
        try await Fixture.clip(mov, seconds: 2)
        let result = await Engine.run(ConvertRequest(inputs: [mov], target: .mp4, quality: .lossless)).results[0]
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.method == "remux")
        #expect(result.fidelity == .lossless)
        #expect(result.verification?.passed == true)
        #expect(result.verification?.checks.contains("compressed samples identical (SHA-256)") == true)
        #expect(result.details["video_codec"] == "h264")
        #expect(result.details["audio_codec"] == "aac")
        #expect(VideoConverter.resource(for: job(mov, .mp4)) == .io)
    }

    @Test("Compressing re-encodes to HEVC and verifies duration, tracks and size")
    func compress() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "clip.mov")
        try await Fixture.clip(mov, seconds: 2, width: 1280, height: 720)
        let result = await Engine.run(ConvertRequest(inputs: [mov], target: nil, verify: true)).results[0]
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.method == "transcode")
        #expect(result.fidelity == .lossy)
        #expect(result.details["video_codec"] == "hevc")
        #expect(result.details["hardware"] == true)
        #expect(result.details["width"] == 1280)
        #expect(result.verification?.passed == true, "\(String(describing: result.verification))")
        #expect((result.bytesOut ?? .max) < result.bytesIn)

        let small = await Engine.run(ConvertRequest(inputs: [mov], target: .mp4, quality: .small, maxDimension: 320, verify: true)).results[
            0]
        #expect(small.status == .ok, "\(String(describing: small.error))")
        #expect(small.details["width"] == 320)
        #expect(small.details["height"] == 180)
        #expect(small.details["audio_codec"] == "aac")
        #expect(small.verification?.passed == true, "\(String(describing: small.verification))")
        #expect(VideoConverter.resource(for: job(mov, .mov)) == .videoEncode)
    }

    @Test("Frame rate is capped by dropping samples")
    func frameRateCap() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "fast.mov")
        try await Fixture.clip(mov, seconds: 1, width: 320, height: 180, fps: 60, audio: false)
        let result = await Engine.run(ConvertRequest(inputs: [mov], target: .mp4, quality: .small, verify: true)).results[0]
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.details["frames"] == 30)
        #expect(result.verification?.passed == true, "\(String(describing: result.verification))")
    }

    @Test("A size budget is met with an average bitrate, or refused up front")
    func maxBytes() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "clip.mov")
        try await Fixture.clip(mov, seconds: 2, width: 1280, height: 720)
        let budget = Engine.fileSize(mov) / 3
        let fits = await Engine.run(ConvertRequest(inputs: [mov], target: .mp4, maxBytes: budget)).results[0]
        #expect(fits.status == .ok, "\(String(describing: fits.error))")
        #expect((fits.bytesOut ?? .max) <= budget)
        let tiny = await Engine.run(ConvertRequest(inputs: [mov], target: .mp4, maxBytes: 1000)).results[0]
        #expect(tiny.error?.code == .sizeUnreachable)
    }

    @Test("Extracting audio copies AAC as is, or decodes to WAV, both verified")
    func extractAudio() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "clip.mov")
        try await Fixture.clip(mov, seconds: 2)
        let m4a = await Engine.run(ConvertRequest(inputs: [mov], target: .m4a, quality: .lossless)).results[0]
        #expect(m4a.status == .ok, "\(String(describing: m4a.error))")
        #expect(m4a.method == "extract")
        #expect(m4a.fidelity == .lossless)
        #expect(m4a.verification?.passed == true)
        #expect(m4a.details["codec"] == "aac")

        let wav = await Engine.run(ConvertRequest(inputs: [mov], target: .wav)).results[0]
        #expect(wav.status == .ok, "\(String(describing: wav.error))")
        #expect(wav.fidelity == .lossless)
        #expect(wav.warnings.contains("lossless from here: the source was already lossy"))
        #expect(wav.verification?.passed == true, "\(String(describing: wav.verification))")
        #expect(wav.details["codec"] == "pcm")
    }

    @Test("GIF: 480 px at 15 fps from the start of the clip")
    func gif() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "clip.mov")
        try await Fixture.clip(mov, seconds: 1)
        let result = await Engine.run(ConvertRequest(inputs: [mov], target: .gif)).results[0]
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.output?.hasSuffix("clip.gif") == true)
        #expect(FileManager.default.fileExists(atPath: result.output ?? ""))
        #expect(result.details["width"] == 480)
        #expect(result.details["frames"] == 15)
        #expect(abs(VideoConverter.gifFrames(duration: 1, fps: 15).reduce(0) { $0 + $1.delay } - 1) < 1e-9)  // no drift
    }

    @Test("Cancelling mid-encode leaves no file behind")
    func cancellation() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "clip.mov")
        try await Fixture.clip(mov, seconds: 6, width: 1280, height: 720)
        let handle = Mutex<Task<ConvertReport, Never>?>(nil)
        let task = Task {
            await Engine.run(ConvertRequest(inputs: [mov], target: nil)) { fraction, _ in
                if fraction > 0.05 { handle.withLock { $0?.cancel() } }
            }
        }
        handle.withLock { $0 = task }
        let result = await task.value.results[0]
        #expect(result.error?.code == .cancelled, "\(result.status) \(String(describing: result.error))")
        #expect(try Fixture.files(in: dir) == ["clip.mov"])
    }

    @Test("Lossless refuses a resize")
    func losslessResize() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "clip.mov")
        try await Fixture.clip(mov, seconds: 1)
        let result = await Engine.run(ConvertRequest(inputs: [mov], target: .mp4, quality: .lossless, maxDimension: 200)).results[0]
        #expect(result.error?.code == .losslessUnavailable)
        #expect(try Fixture.files(in: dir) == ["clip.mov"])
    }

    @Test("Inspect reports the video essentials")
    func inspect() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "clip.mov")
        try await Fixture.clip(mov, seconds: 1)
        let meta = await Engine.inspect(mov).meta
        #expect(meta["width"] == 640)
        #expect(meta["height"] == 360)
        #expect(meta["fps"] == 30.0)
        #expect(meta["video_codec"] == "h264")
        #expect(meta["audio_codec"] == "aac")
        #expect(meta["has_audio"] == true)
        #expect(meta["duration_s"] == 1.0)
        #expect(meta["bitrate"] != nil)
    }

    private func job(_ url: URL, _ target: Format) -> Job {
        Job(
            input: url, source: .mov, target: target, quality: .balanced, maxBytes: nil, maxDimension: nil, stripMetadata: false,
            verify: false,
            output: url, progress: { _ in })
    }
}

/// Timings for the report. Run with `FOLIO_BENCH=1 make test`.
@Suite("Media benchmarks", .enabled(if: ProcessInfo.processInfo.environment["FOLIO_BENCH"] != nil))
struct MediaBenchmarks {
    @Test func audio() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "five-minutes.wav")
        try Fixture.tone(wav, seconds: 300, settings: Fixture.pcm())
        for target in [Format.flac, .m4a, .alac] {
            let report = await Engine.run(ConvertRequest(inputs: [wav], target: target))
            let r = report.results[0]
            print(
                "BENCH 5 min wav → \(target.rawValue): \(r.durationMs) ms, \(r.bytesIn / 1_000_000) MB → \((r.bytesOut ?? 0) / 1_000_000) MB, verified \(r.verification?.passed ?? false)"
            )
        }
    }

    @Test func video() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appending(path: "thirty-1080p.mov")
        try await Fixture.clip(mov, seconds: 30, width: 1920, height: 1080)
        for (target, quality) in [(Format.mp4, Quality.balanced), (nil, .balanced), (.mp4, .small), (.m4a, .balanced), (.gif, .balanced)] {
            let r = await Engine.run(ConvertRequest(inputs: [mov], target: target, quality: quality)).results[0]
            print(
                "BENCH 30 s 1080p → \(target?.rawValue ?? "compress") \(quality.rawValue): \(r.durationMs) ms, \(r.method ?? "-"), \(r.bytesIn / 1_000_000) MB → \(Double(r.bytesOut ?? 0) / 1e6) MB, \(r.status) \(r.error?.message ?? "")"
            )
        }
    }
}
