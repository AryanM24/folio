import AVFoundation  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import Synchronization
import Testing

@testable import FolioConvert

/// Two copies of a fixture clip end to end, with a video composition and an audio fade:
/// the shape the timeline render engine hands the encoder.
private struct Timeline {
    let composition: AVMutableComposition
    let video: AVVideoComposition
    let mix: AVAudioMix

    init(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        composition = AVMutableComposition()
        let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let videoTrack = try await asset.loadTracks(withMediaType: .video)[0]
        try v.insertTimeRange(range, of: videoTrack, at: .zero)
        try v.insertTimeRange(range, of: videoTrack, at: range.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let parameters = AVMutableAudioMixInputParameters()
        if let audioTrack = audioTracks.first {
            let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try a.insertTimeRange(range, of: audioTrack, at: .zero)
            try a.insertTimeRange(range, of: audioTrack, at: range.duration)
            parameters.trackID = a.trackID
            parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: range.duration, duration: range.duration))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        self.mix = mix
        video = try await AVVideoComposition.videoComposition(withPropertiesOf: composition)
    }

    func encode(_ settings: EncodeSettings, to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws
        -> EncodeResult
    {
        try await CompositionEncoder.encode(composition, videoComposition: video, audioMix: mix, settings: settings, to: url, progress: progress)
    }
}

private func format(_ url: URL, _ type: AVMediaType) async throws -> CMFormatDescription? {
    try await AVURLAsset(url: url).loadTracks(withMediaType: type).first?.load(.formatDescriptions).first
}

@Suite("Composition encode", .timeLimit(.minutes(1)))
struct CompositionEncodeTests {
    @Test("A composition encodes to HEVC with the right codec, duration, size and sound")
    func hevc() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appending(path: "clip.mov")
        try await Fixture.clip(clip, seconds: 1)
        let out = dir.appending(path: "out.mp4")
        let result = try await Timeline(clip).encode(EncodeSettings(), to: out)
        #expect(result.width == 640 && result.height == 360)
        #expect(result.frames == 60)
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
        let video = try #require(try await format(out, .video))
        #expect(CMFormatDescriptionGetMediaSubType(video) == kCMVideoCodecType_HEVC)
        #expect(CMVideoFormatDescriptionGetDimensions(video).width == 640)
        #expect(try await format(out, .audio).map(CMFormatDescriptionGetMediaSubType) == kAudioFormatMPEG4AAC)
    }

    @Test("Scaling fits the picture; H.264 at constant quality works too")
    func h264Scaled() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appending(path: "clip.mov")
        try await Fixture.clip(clip, seconds: 1)
        let out = dir.appending(path: "out.mp4")
        let settings = EncodeSettings(video: .init(codec: .h264, width: 320, height: 180))
        _ = try await Timeline(clip).encode(settings, to: out)
        let video = try #require(try await format(out, .video))
        #expect(CMFormatDescriptionGetMediaSubType(video) == kCMVideoCodecType_H264)
        #expect(CMVideoFormatDescriptionGetDimensions(video).width == 320)
        #expect(CMVideoFormatDescriptionGetDimensions(video).height == 180)
    }

    @Test("A byte budget is met within 5 %, or refused before writing")
    func maxBytes() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appending(path: "clip.mov")
        try await Fixture.clip(clip, seconds: 2, width: 1280, height: 720)
        let timeline = try await Timeline(clip)
        let out = dir.appending(path: "out.mp4")
        let budget: Int64 = 400_000
        let result = try await timeline.encode(EncodeSettings(audio: .aac(bitrate: 64_000), maxBytes: budget), to: out)
        #expect(result.targetBitrate != nil)
        #expect(Engine.fileSize(out) <= budget * 105 / 100, "\(Engine.fileSize(out)) bytes")

        let tiny = dir.appending(path: "tiny.mp4")
        await #expect {
            _ = try await timeline.encode(EncodeSettings(maxBytes: 5_000), to: tiny)
        } throws: { ($0 as? ConvertError)?.code == .sizeUnreachable }
        #expect(!FileManager.default.fileExists(atPath: tiny.path))
    }

    @Test("The frame-rate cap drops frames")
    func frameRateCap() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appending(path: "clip.mov")
        try await Fixture.clip(clip, seconds: 1, width: 320, height: 180, fps: 60, audio: false)
        let result = try await Timeline(clip).encode(EncodeSettings(video: .init(maxFrameRate: 30)), to: dir.appending(path: "out.mp4"))
        #expect(result.frames == 60)  // 2 s at 30 fps, from 120 frames
    }

    @Test("HDR writes 10-bit HEVC tagged BT.2020 HLG; H.264 refuses it")
    func hdr() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appending(path: "clip.mov")
        try await Fixture.clip(clip, seconds: 1, width: 320, height: 180, audio: false)
        let timeline = try await Timeline(clip)
        let out = dir.appending(path: "hdr.mov")
        _ = try await timeline.encode(EncodeSettings(video: .init(hdr: .hlg), fileType: .mov), to: out)
        let video = try #require(try await format(out, .video))
        #expect(CMFormatDescriptionGetMediaSubType(video) == kCMVideoCodecType_HEVC)
        let transfer = CMFormatDescriptionGetExtension(video, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        #expect(transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String))
        let primaries = CMFormatDescriptionGetExtension(video, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        #expect(primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String))
        let bits = CMFormatDescriptionGetExtension(video, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
        #expect(bits == nil || bits == 10)

        await #expect {
            _ = try await timeline.encode(EncodeSettings(video: .init(codec: .h264, tenBit: true)), to: dir.appending(path: "no.mp4"))
        } throws: { ($0 as? ConvertError)?.code == .unsupportedPair }
    }

    @Test("HEVC with alpha and ProRes masters")
    func alphaAndProRes() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appending(path: "clip.mov")
        try await Fixture.clip(clip, seconds: 1, width: 320, height: 180)
        let timeline = try await Timeline(clip)
        let alpha = dir.appending(path: "alpha.mov")
        _ = try await timeline.encode(EncodeSettings(video: .init(codec: .hevcWithAlpha), fileType: .mov), to: alpha)
        let alphaFormat = try #require(try await format(alpha, .video))
        #expect(CMFormatDescriptionGetMediaSubType(alphaFormat) == kCMVideoCodecType_HEVC)
        #expect(CMFormatDescriptionGetExtension(alphaFormat, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool == true)

        let master = dir.appending(path: "master.mov")
        _ = try await timeline.encode(EncodeSettings(video: .init(codec: .proRes422), audio: .pcm, fileType: .mov), to: master)
        #expect(try await format(master, .video).map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_AppleProRes422)
        #expect(try await format(master, .audio).map(CMFormatDescriptionGetMediaSubType) == kAudioFormatLinearPCM)
        await #expect {
            _ = try await timeline.encode(
                EncodeSettings(video: .init(codec: .proRes422), fileType: .mov, maxBytes: 1_000_000), to: dir.appending(path: "no.mov"))
        } throws: { ($0 as? ConvertError)?.code == .unsupportedPair }
    }

    @Test("Sound only: the audio mix to WAV")
    func audioOnly() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appending(path: "clip.mov")
        try await Fixture.clip(clip, seconds: 1, width: 320, height: 180)
        let out = dir.appending(path: "mix.wav")
        let result = try await Timeline(clip).encode(EncodeSettings(video: nil, audio: .pcm, fileType: .wav), to: out)
        #expect(result.frames == 0)
        let asset = AVURLAsset(url: out)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
    }

    @Test("Cancelling mid-encode leaves no file")
    func cancellation() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appending(path: "clip.mov")
        try await Fixture.clip(clip, seconds: 4, width: 1280, height: 720)
        let timeline = try await Timeline(clip)
        let out = dir.appending(path: "out.mp4")
        let handle = Mutex<Task<EncodeResult, any Error>?>(nil)
        let task = Task {
            try await timeline.encode(EncodeSettings(), to: out) { fraction in
                if fraction > 0.05 { handle.withLock { $0?.cancel() } }
            }
        }
        handle.withLock { $0 = task }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let left = try Fixture.files(in: dir)
        #expect(left == ["clip.mov"], "\(left)")
    }
}
