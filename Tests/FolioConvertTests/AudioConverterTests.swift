import AVFoundation  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import Testing

@testable import FolioConvert

/// Fixtures made at test time, so the repo carries no binary media.
enum Fixture {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pcm(bits: Int = 16, rate: Double = 48_000, channels: Int = 2, bigEndian: Bool = false) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: bigEndian,
        ]
    }

    static var aac: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
    }

    /// Two detuned sines plus a little deterministic noise, so lossless codecs have real work to do.
    static func tone(_ url: URL, seconds: Double, settings: [String: Any]) throws {
        let rate = settings[AVSampleRateKey] as? Double ?? 48_000
        let channels = settings[AVNumberOfChannelsKey] as? Int ?? 2
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioFrameCount(rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        var seed: UInt64 = 42
        var written = 0
        let total = Int(seconds * rate)
        while written < total {
            let n = min(Int(chunk), total - written)
            buffer.frameLength = AVAudioFrameCount(n)
            for c in 0..<channels {
                let p = buffer.floatChannelData![c]
                for i in 0..<n {
                    let t = Double(written + i) / rate
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let noise = Double(Int64(bitPattern: seed >> 11) % 1000) / 1000
                    p[i] = Float(
                        0.3 * sin(2 * .pi * 220 * t * (1 + 0.01 * Double(c))) + 0.2 * sin(2 * .pi * 660 * t) * sin(t) + 0.03 * noise)
                }
            }
            try file.write(from: buffer)
            written += n
        }
        file.close()
    }

    static func files(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
}

@Suite("Audio", .timeLimit(.minutes(1)))
struct AudioConverterTests {
    @Test("Targets: lossless where it can be, compress in place only for m4a, never mp3")
    func targets() {
        let wav = AudioConverter.targets(from: .wav).map(\.to)
        #expect(Set(wav) == [.m4a, .alac, .flac, .aiff])
        #expect(AudioConverter.targets(from: .m4a).contains { $0.to == .m4a && !$0.losslessAvailable })
        #expect(AudioConverter.targets(from: .mp3).allSatisfy { $0.to != .mp3 })
        #expect(AudioConverter.targets(from: .flac).first { $0.to == .alac }?.losslessAvailable == true)
    }

    @Test("wav → flac → wav is sample-identical and verified")
    func flacRoundTrip() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "tone.wav")
        try Fixture.tone(wav, seconds: 3, settings: Fixture.pcm())

        let flac = await Engine.run(ConvertRequest(inputs: [wav], target: .flac, quality: .lossless)).results[0]
        #expect(flac.status == .ok)
        #expect(flac.fidelity == .lossless)
        #expect(flac.verification?.passed == true)
        #expect(flac.verification?.metrics["differing_samples"] == 0)
        #expect(flac.details["bit_depth"] == 16)
        #expect((flac.bytesOut ?? .max) < flac.bytesIn)

        let back = await Engine.run(
            ConvertRequest(inputs: [URL(fileURLWithPath: flac.output!)], target: .wav, outputDirectory: dir.appending(path: "back"))
        )
        .results[0]
        #expect(back.status == .ok)
        let check = try AudioVerify.compare(wav, URL(fileURLWithPath: back.output!), as: .pcmFormatInt16)
        #expect(check.passed)
    }

    @Test("24-bit aiff → alac keeps 24 bits, verified")
    func twentyFourBit() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = dir.appending(path: "hi.aiff")
        try Fixture.tone(aiff, seconds: 1, settings: Fixture.pcm(bits: 24, bigEndian: true))
        let result = await Engine.run(ConvertRequest(inputs: [aiff], target: .alac, quality: .lossless)).results[0]
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.output?.hasSuffix(".m4a") == true)
        #expect(result.details["codec"] == "alac")
        #expect(result.details["bit_depth"] == 24)
        #expect(result.verification?.passed == true)
    }

    @Test("AAC → ALAC is labelled lossless from here")
    func lossySourceWarns() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m4a = dir.appending(path: "song.m4a")
        try Fixture.tone(m4a, seconds: 2, settings: Fixture.aac)
        let result = await Engine.run(ConvertRequest(inputs: [m4a], target: .alac, quality: .lossless)).results[0]
        #expect(result.status == .ok, "\(String(describing: result.error))")
        #expect(result.fidelity == .lossless)
        #expect(result.warnings.contains("lossless from here: the source was already lossy"))
        #expect(result.verification?.passed == true)
        #expect(result.output?.hasSuffix("song 2.m4a") == true)  // never overwrites the input
    }

    @Test("Lossless into AAC is refused")
    func losslessRefusal() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "tone.wav")
        try Fixture.tone(wav, seconds: 0.5, settings: Fixture.pcm())
        let result = await Engine.run(ConvertRequest(inputs: [wav], target: .m4a, quality: .lossless)).results[0]
        #expect(result.error?.code == .losslessUnavailable)
        #expect(try Fixture.files(in: dir) == ["tone.wav"])
    }

    @Test("wav → m4a: AAC 256 balanced, HE-AAC small, both much smaller")
    func aac() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "tone.wav")
        try Fixture.tone(wav, seconds: 3, settings: Fixture.pcm())
        let balanced = await Engine.run(ConvertRequest(inputs: [wav], target: .m4a, verify: true)).results[0]
        #expect(balanced.status == .ok)
        #expect(balanced.fidelity == .visuallyLossless)
        #expect(balanced.details["codec"] == "aac")
        #expect(balanced.verification?.passed == true)
        #expect((balanced.ratio ?? 1) < 0.3)
        let small = await Engine.run(ConvertRequest(inputs: [wav], target: .m4a, quality: .small)).results[0]
        #expect(small.fidelity == .lossy)
        #expect(small.details["codec"] == "he-aac")
        #expect((small.bytesOut ?? .max) < (balanced.bytesOut ?? 0))
    }

    @Test("Compressing compact AAC keeps the original (never bigger)")
    func neverBigger() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m4a = dir.appending(path: "song.m4a")
        try Fixture.tone(m4a, seconds: 2, settings: Fixture.aac)
        let result = await Engine.run(ConvertRequest(inputs: [m4a], target: nil)).results[0]
        #expect(result.status == .skipped)
        #expect(result.method == "copy")
        #expect(result.warnings.contains { $0.hasPrefix("Already compact") })
        #expect(try Fixture.files(in: dir) == ["song.m4a"])
    }

    @Test("Inspect reports the audio essentials")
    func inspect() async throws {
        let dir = try Fixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "tone.wav")
        try Fixture.tone(wav, seconds: 1, settings: Fixture.pcm())
        let info = await Engine.inspect(wav)
        #expect(info.meta["duration_s"] == 1.0)
        #expect(info.meta["sample_rate"] == 48_000)
        #expect(info.meta["channels"] == 2)
        #expect(info.meta["codec"] == "pcm")
        #expect(info.meta["bit_depth"] == 16)
        #expect(info.meta["bitrate"] != nil)
    }
}
