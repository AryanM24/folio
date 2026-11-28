import AVFoundation
import CoreGraphics
import ImageIO
import Synchronization
import Testing

@testable import FolioMedia

// MARK: - Fixtures

/// Media for the analysis tests, generated per test so nothing lives in the repo.
nonisolated private enum Fixtures {
    /// A cache in its own temporary folder, so tests never see each other's results.
    static func cache() -> AnalysisCache {
        AnalysisCache(root: FileManager.default.temporaryDirectory.appending(path: "FolioAnalysisCache-\(UUID().uuidString)"))
    }

    static func wav(_ samples: [Float], rate: Double, in folder: URL, name: String = "sound.wav") throws -> URL {
        let url = folder.appending(path: name)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let data = buffer.floatChannelData?[0]
        else { throw CocoaError(.fileWriteUnknown) }
        samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            ])
        try file.write(from: buffer)
        return url
    }

    static func sine(seconds: Double, rate: Double, amplitude: Float, frequency: Float = 440) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * frequency * Float($0) / Float(rate)) }
    }

    static func noise(seconds: Double, rate: Double, amplitude: Float) -> [Float] {
        var rng = SplitMix(seed: 7)
        return (0..<Int(seconds * rate)).map { _ in Float.random(in: -1...1, using: &rng) * amplitude }
    }

    /// Spoken by the system voice, so the transcriber has real speech. Waits without blocking.
    static func speech(_ text: String, in folder: URL) async throws -> URL {
        let url = folder.appending(path: "speech.aiff")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/say")
        process.arguments = ["-o", url.path(percentEncoded: false), text]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { p in
                p.terminationStatus == 0 ? continuation.resume() : continuation.resume(throwing: CocoaError(.fileWriteUnknown))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        return url
    }

    /// An H.264 .mov with every frame a keyframe; `draw` fills each BGRA frame.
    static func movie(
        in folder: URL, name: String = "movie.mov", frames: Int, fps: Int32 = 30, width: Int, height: Int,
        draw: (Int, UnsafeMutablePointer<UInt8>, Int) -> Void
    ) async throws -> URL {
        let url = folder.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoAverageBitRateKey: 4_000_000],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var made: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            draw(i, CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    static func fill(_ base: UnsafeMutablePointer<UInt8>, row: Int, width: Int, height: Int, bgr: (UInt8, UInt8, UInt8)) {
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * row + x * 4
                (p[0], p[1], p[2], p[3]) = (bgr.0, bgr.1, bgr.2, 255)
            }
        }
    }

    /// Blocky grey noise: texture for registration to lock onto.
    static func texture(width: Int, height: Int, block: Int = 4) -> [UInt8] {
        var rng = SplitMix(seed: 42)
        let cols = width / block + 1, rows = height / block + 1
        let cells = (0..<cols * rows).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return (0..<width * height).map { i in cells[(i / width / block) * cols + (i % width) / block] }
    }

    /// Mean of the first plane (luma, or blue for BGRA) of frame `index`.
    static func meanLuma(_ url: URL, at time: CMTime) async throws -> Double {
        let image = try await Frames.still(url, at: time)
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let count = image.width * image.height
        return (0..<count).reduce(0.0) { $0 + Double(bytes[$1]) } / Double(count)
    }

    static func rms(_ samples: ArraySlice<Float>) -> Double {
        20 * log10((samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))).squareRoot() + 1e-9)
    }

    static func read(_ url: URL, rate: Double) async throws -> [Float] {
        var all: [Float] = []
        try await AudioReader.read(url, sampleRate: rate, channels: 1) { all.append(contentsOf: $0) }
        return all
    }
}

/// Deterministic random numbers, so fixtures are the same every run.
nonisolated private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

nonisolated private func word(_ text: String, _ start: Double, _ end: Double) -> Word {
    Word(text: text, range: TimeRange(start: Time(seconds: start), end: Time(seconds: end)))
}

// MARK: - Speech

@Suite("Transcription", .timeLimit(.minutes(1)))
nonisolated struct TranscriberTests {
    @Test(.enabled(if: Transcriber.isAvailable, "Speech transcription isn't available on this Mac"))
    func transcribesSpeechWithTimes() async throws {
        let folder = try TestMedia.folder()
        let audio = try await Fixtures.speech("Welcome to Folio. The quick brown fox jumps over the lazy dog.", in: folder)
        let source = SourceID()
        let cache = Fixtures.cache()
        let stages = Mutex<Set<String>>([])
        let clock = ContinuousClock.now
        let transcript = try await Transcriber.transcribe(audio, source: source, locale: Locale(identifier: "en-US"), cache: cache) {
            stage, _ in
            stages.withLock { _ = $0.insert("\(stage)") }
        }
        print("Transcribed \(transcript.words.count) words in \(clock.duration(to: .now))")

        #expect(transcript.sourceID == source)
        let text = transcript.words.map { FillerWords.normalized($0.text) }.joined(separator: " ")
        #expect(text.contains("quick brown fox"), "got: \(text)")
        for (a, b) in zip(transcript.words, transcript.words.dropFirst()) {
            #expect(a.range.start <= b.range.start)
            #expect(a.range.end <= b.range.end)
        }
        #expect(transcript.words.allSatisfy { $0.range.duration >= .zero })
        #expect(stages.withLock { $0.contains("transcribing") })

        // Captions from real output: the first sentence stays its own cue.
        let cues = CueSplitter.cues(for: transcript)
        #expect(cues.first.map { CueSplitter.endsSentence($0.words.last!.text) } == true, "\(cues.map(\.text))")

        // Second run: from the cache, same words.
        let again = try await Transcriber.transcribe(audio, source: source, locale: Locale(identifier: "en-US"), cache: cache)
        #expect(again.words == transcript.words)
    }
}

@Suite("Caption cues", .timeLimit(.minutes(1)))
nonisolated struct CueSplitterTests {
    @Test func breaksAtSentencesPausesAndLimits() {
        let words = [
            word("Hello", 0, 0.3), word("there.", 0.3, 0.6),  // sentence end
            word("This", 0.7, 0.9), word("is", 0.9, 1.0), word("a", 1.0, 1.1), word("test", 1.1, 1.4),
            word("after", 2.4, 2.6), word("a", 2.6, 2.7), word("pause", 2.7, 3.0),  // 1 s pause before
        ]
        let cues = CueSplitter.cues(from: words, source: nil)
        #expect(cues.map(\.text) == ["Hello there.", "This is a test", "after a pause"])
        #expect(cues[1].range == TimeRange(start: Time(seconds: 0.7), end: Time(seconds: 1.4)))
        #expect(cues[1].words.count == 4)
    }

    @Test func respectsWordCountDurationAndCharacters() {
        let many = (0..<20).map { word("w\($0)", Double($0) * 0.2, Double($0) * 0.2 + 0.15) }
        var rules = CueSplitter.Rules()
        rules.maxWords = 5
        #expect(CueSplitter.cues(from: many, source: nil, rules: rules).allSatisfy { $0.words.count <= 5 })

        rules = CueSplitter.Rules()
        rules.maxWords = 100
        rules.maxDuration = Time(value: 1, timescale: 1)
        #expect(CueSplitter.cues(from: many, source: nil, rules: rules).allSatisfy { $0.range.duration <= Time(value: 1, timescale: 1) })

        let long = (0..<12).map { word("wordy\($0)", Double($0) * 0.1, Double($0) * 0.1 + 0.09) }
        rules = CueSplitter.Rules()
        rules.maxWords = 100
        rules.maxCharactersPerLine = 20
        for cue in CueSplitter.cues(from: long, source: nil, rules: rules) {
            let lines = cue.text.split(separator: "\n")
            #expect(lines.count <= 2)
            #expect(cue.text.count <= 41)
        }
    }

    @Test func balancesTwoLines() {
        #expect(
            CueSplitter.lines(["one", "two", "three", "four", "five", "six"], width: 15, maxLines: 2) == "one two three\nfour five six")
        #expect(CueSplitter.lines(["short"], width: 15, maxLines: 2) == "short")
    }

    @Test func styleRules() {
        var style = CaptionStyle()
        style.maxWords = 3
        #expect(CueSplitter.Rules(style: style).maxWords == 3)
    }
}

@Suite("Filler words", .timeLimit(.minutes(1)))
nonisolated struct FillerWordTests {
    @Test func findsHesitationsAndSetOffLike() {
        let transcript = Transcript(
            sourceID: SourceID(), locale: "en-US",
            words: [
                word("So,", 0, 0.2), word("um,", 0.3, 0.5), word("it", 0.6, 0.7), word("was,", 0.7, 0.9), word("like,", 0.9, 1.1),
                word("huge.", 1.1, 1.4), word("I", 1.5, 1.6), word("like", 1.6, 1.8), word("it.", 1.8, 2.0), word("Uh", 2.5, 2.7),
            ])
        let found = FillerWords.find(in: transcript).map(\.text)
        #expect(found == ["um,", "like,", "Uh"])
        #expect(FillerWords.find(in: transcript, includeLike: false).map(\.text) == ["um,", "Uh"])
    }
}

// MARK: - Audio

@Suite("Silence", .timeLimit(.minutes(1)))
nonisolated struct SilenceTests {
    @Test func findsTheGapBetweenTones() async throws {
        let folder = try TestMedia.folder()
        let rate = 44_100.0
        let samples =
            Fixtures.sine(seconds: 1, rate: rate, amplitude: 0.5) + [Float](repeating: 0, count: Int(rate))
            + Fixtures.sine(seconds: 1, rate: rate, amplitude: 0.5)
        let url = try Fixtures.wav(samples, rate: rate, in: folder)
        let cache = Fixtures.cache()
        let reached = Mutex(0.0)
        let ranges = try await Silence.ranges(in: url, cache: cache) { p in reached.withLock { $0 = max($0, p) } }
        #expect(ranges.count == 1)
        let gap = try #require(ranges.first)
        #expect(abs(gap.start.seconds - 1.1) < 0.02)
        #expect(abs(gap.end.seconds - 1.9) < 0.02)
        #expect(reached.withLock { $0 } > 0.95)

        // Cached peaks; a new threshold needs no reread.
        #expect(try await Silence.ranges(in: url, parameters: .init(minimumDuration: Time(value: 2, timescale: 1)), cache: cache).isEmpty)
    }

    @Test func skipsShortPausesAndPadsOnlyInside() {
        var peaks = [Float](repeating: 0.5, count: 300)
        for i in 0..<50 { peaks[i] = 0 }  // 0.5 s lead-in
        for i in 120..<140 { peaks[i] = 0 }  // 0.2 s: speech rhythm, kept
        let ranges = Silence.ranges(peaks: peaks, binDuration: 0.01, parameters: .init())
        #expect(ranges == [TimeRange(start: .zero, end: Time(seconds: 0.4))])
    }
}

@Suite("Loudness", .timeLimit(.minutes(1)))
nonisolated struct LoudnessTests {
    @Test func measuresASineAndNormalises() async throws {
        let folder = try TestMedia.folder()
        // BS.1770: a full-scale 1 kHz sine in one channel reads −3.01 LUFS, so half scale is −9.03.
        let url = try Fixtures.wav(Fixtures.sine(seconds: 3, rate: 48_000, amplitude: 0.5, frequency: 997), rate: 48_000, in: folder)
        let m = try await Loudness.measure(url, cache: nil)
        #expect(abs(m.integrated - -9.03) < 0.3, "got \(m.integrated)")
        #expect(abs(m.peak - -6.02) < 0.1)
        #expect(abs(Loudness.normalizationGain(for: m, target: -14) - -4.97) < 0.3)
        // Quiet material is held back by the peak ceiling.
        #expect(abs(Loudness.normalizationGain(for: m, target: 0, ceiling: -1) - 5.02) < 0.1)
    }

    @Test func silenceHasNoLoudness() async throws {
        let folder = try TestMedia.folder()
        let url = try Fixtures.wav([Float](repeating: 0, count: 48_000), rate: 48_000, in: folder)
        let cache = Fixtures.cache()
        let m = try await Loudness.measure(url, cache: cache)
        #expect(m.integrated == -.infinity)
        #expect(Loudness.normalizationGain(for: m) == 0)
        // −∞ survives the JSON cache.
        #expect(try await Loudness.measure(url, cache: cache) == m)
    }
}

@Suite("Voice isolation", .timeLimit(.minutes(1)))
nonisolated struct VoiceIsolationTests {
    @Test(.enabled(if: VoiceIsolation.isSoundIsolationAvailable, "AUSoundIsolation isn't on this Mac"))
    func removesNoiseKeepsVoice() async throws {
        let folder = try TestMedia.folder()
        let speech = try await Fixtures.read(try await Fixtures.speech("Folio cleans up noisy voice recordings.", in: folder), rate: 48_000)
        let rate = 48_000.0
        let clean = [Float](repeating: 0, count: Int(rate)) + speech
        let noise = Fixtures.noise(seconds: Double(clean.count) / rate, rate: rate, amplitude: 0.0316)
        let noisy = zip(clean, noise).map { $0 + $1 }
        let url = try Fixtures.wav(noisy, rate: rate, in: folder, name: "noisy.wav")

        let out = try await Fixtures.read(
            try await VoiceIsolation.isolate(url, method: .soundIsolation, cache: Fixtures.cache()), rate: rate)
        #expect(abs(out.count - noisy.count) < 64)
        // Skip the unit's warm-up; measure the noise-only second.
        let before = Fixtures.rms(noisy[24_000..<48_000]), after = Fixtures.rms(out[24_000..<48_000])
        #expect(before - after > 30, "noise \(before) → \(after) dBFS")
        let voiceBefore = Fixtures.rms(noisy[60_000..<noisy.count - 1000]), voiceAfter = Fixtures.rms(out[60_000..<out.count - 1000])
        #expect(voiceBefore - voiceAfter < 6, "voice \(voiceBefore) → \(voiceAfter) dBFS")
    }

    @Test func gateTurnsDownNoiseBetweenTones() async throws {
        let folder = try TestMedia.folder()
        let rate = 48_000.0
        let tone = Fixtures.sine(seconds: 0.5, rate: rate, amplitude: 0.3)
        let signal = tone + [Float](repeating: 0, count: Int(rate)) + tone
        let noise = Fixtures.noise(seconds: 2, rate: rate, amplitude: 0.003)  // ≈ −55 dBFS
        let url = try Fixtures.wav(zip(signal, noise).map { $0 + $1 }, rate: rate, in: folder)
        let out = try await Fixtures.read(try await VoiceIsolation.isolate(url, method: .noiseGate, cache: Fixtures.cache()), rate: rate)
        let input = zip(signal, noise).map { $0 + $1 }
        #expect(Fixtures.rms(input[48_000..<67_000]) - Fixtures.rms(out[48_000..<67_000]) > 30)
        #expect(abs(Fixtures.rms(input[5_000..<20_000]) - Fixtures.rms(out[5_000..<20_000])) < 1)
    }
}

@Suite("Beats", .timeLimit(.minutes(1)))
nonisolated struct BeatDetectionTests {
    @Test func findsClicks() async throws {
        let folder = try TestMedia.folder()
        let rate = 44_100.0
        var samples = [Float](repeating: 0, count: Int(rate * 2))
        for beat in [0.25, 0.75, 1.25, 1.75] {
            let start = Int(beat * rate)
            for i in 0..<441 { samples[start + i] = 0.8 * sin(Float(i) * 0.3) * (1 - Float(i) / 441) }
        }
        let url = try Fixtures.wav(samples, rate: rate, in: folder)
        let onsets = try await BeatDetection.onsets(in: url, cache: nil)
        #expect(onsets.count == 4)
        for (onset, beat) in zip(onsets, [0.25, 0.75, 1.25, 1.75]) {
            #expect(abs(onset.time.seconds - beat) < 0.02, "onset at \(onset.time.seconds)")
        }
    }
}

// MARK: - Video

@Suite("Scenes", .timeLimit(.minutes(1)))
nonisolated struct SceneDetectionTests {
    @Test func findsAHardCutButNotAFade() async throws {
        let folder = try TestMedia.folder()
        let cut = try await Fixtures.movie(in: folder, frames: 60, width: 64, height: 64) { i, base, row in
            Fixtures.fill(base, row: row, width: 64, height: 64, bgr: i < 30 ? (0, 0, 220) : (220, 40, 0))
        }
        let cuts = try await SceneDetection.cuts(in: cut, cache: nil)
        #expect(cuts.count == 1)
        #expect(cuts.first.map { abs($0.seconds - 1) < 0.001 } == true)

        let fade = try await TestMedia.video(in: folder, seconds: 2, fps: 30, width: 64, height: 64)
        #expect(try await SceneDetection.cuts(in: fade, cache: nil).isEmpty)
    }
}

@Suite("Stabilization", .timeLimit(.minutes(1)))
nonisolated struct StabilizerTests {
    @Test func registrationRecoversASyntheticShift() throws {
        let size = 256
        let pixels = Fixtures.texture(width: size, height: size)
        let gray = CGColorSpaceCreateDeviceGray()
        func image(dx: CGFloat, dy: CGFloat) -> CGImage {
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let base = CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size, space: gray, bitmapInfo: [],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: gray,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(base, in: CGRect(x: dx, y: dy, width: CGFloat(size), height: CGFloat(size)))  // y up
            return context.makeImage()!
        }
        // Content moves right 12 and down 7 (CG's y is up, so −7).
        let step = try Stabilizer.step(from: image(dx: 0, dy: 0), to: image(dx: 12, dy: -7))
        #expect(abs(step.x * Double(size) - 12) < 0.5, "x \(step.x * Double(size))")
        #expect(abs(step.y * Double(size) - 7) < 0.5, "y \(step.y * Double(size))")
    }

    @Test func correctsJitterAgainstTheShake() async throws {
        let folder = try TestMedia.folder()
        let width = 160, height = 120
        let texture = Fixtures.texture(width: width + 8, height: height)
        // Every other frame jumps 4 px right.
        let url = try await Fixtures.movie(in: folder, frames: 40, width: width, height: height) { i, base, row in
            let shift = i % 2 == 1 ? 4 : 0
            for y in 0..<height {
                for x in 0..<width {
                    let v = texture[y * (width + 8) + (x + 4 - shift)]
                    let p = base + y * row + x * 4
                    (p[0], p[1], p[2], p[3]) = (v, v, v, 255)
                }
            }
        }
        let cache = Fixtures.cache()
        let path = try await Stabilizer.path(for: url, strength: 0.7, cache: cache)
        #expect(path.offsets.count == 40)
        // Jumped frames move back left, the others right, about half the jump each.
        for i in 10..<30 {
            let px = path.offsets[i].x * Double(width)
            #expect(i % 2 == 1 ? (-3 ... -1).contains(px) : (1...3).contains(px), "frame \(i): \(px) px")
            #expect(abs(path.offsets[i].y * Double(height)) < 0.5)
        }
        #expect(path.zoom > 1 && path.zoom <= Stabilizer.maxZoom)
        // The cached registration serves another strength without decoding.
        #expect(Stabilizer.cachedPath(for: url, strength: 0.2, cache: cache)?.offsets.count == 40)

        // The Core Image transform moves the frame by the offset (y up there).
        let t = path.transform(at: path.times[11], size: CGSize(width: width, height: height))
        let centre = CGPoint(x: Double(width) / 2, y: Double(height) / 2).applying(t)
        #expect(abs(centre.x - Double(width) / 2 - path.offsets[11].x * Double(width) * path.zoom) < 0.01)
    }

    @Test func pathSmoothsAndClampsToTheZoomLimit() {
        let times = (0..<10).map { Time(value: Int64($0), timescale: 30) }
        let drift = Stabilizer.Motion(times: times, steps: [.zero] + Array(repeating: Vec2(x: 0.1, y: 0), count: 9))
        let path = Stabilizer.path(drift, strength: 1, framesPerSecond: 30)
        #expect(path.zoom <= Stabilizer.maxZoom + 1e-9)
        #expect(path.offsets.allSatisfy { abs($0.x) <= (Stabilizer.maxZoom - 1) / 2 + 1e-9 })
        #expect(path.offset(at: Time(seconds: 0.05)) == path.offsets[1])
    }
}

nonisolated private let penguin = URL(filePath: "/Library/User Pictures/Animals/Penguin.heic")

@Suite("Segmentation", .timeLimit(.minutes(1)))
nonisolated struct SegmentationTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: penguin.path(percentEncoded: false)), "No system penguin picture to segment"))
    func subjectMaskMovie() async throws {
        let folder = try TestMedia.folder()
        let source = try #require(CGImageSourceCreateWithURL(penguin as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let side = 256
        let url = try await Fixtures.movie(in: folder, frames: 6, fps: 6, width: side, height: side) { _, base, row in
            let context = CGContext(
                data: base, width: side, height: side, bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let cache = Fixtures.cache()
        var parameters = Segmentation.Parameters()
        parameters.subject = .subject
        #expect(Segmentation.cachedMaskMovie(for: url, parameters: parameters, cache: cache) == nil)
        let clock = ContinuousClock.now
        let masks = try await Segmentation.maskMovie(for: url, parameters: parameters, cache: cache)
        print("masks in \(clock.duration(to: .now))")
        #expect(Segmentation.cachedMaskMovie(for: url, parameters: parameters, cache: cache) == masks)

        var coverages: [Double] = []
        var corners: [UInt8] = []
        try await VideoFrameReader.read(masks, maxDimension: 4096, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            _, pixels in
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
            var on = 0
            for y in 0..<h { for x in 0..<w where luma[y * row + x] > 128 { on += 1 } }
            coverages.append(Double(on) / Double(w * h))
            corners.append(luma[0])
        }
        #expect(coverages.count == 6)
        // The research run measured 30 % for this picture.
        #expect(coverages.allSatisfy { (0.1...0.6).contains($0) }, "\(coverages)")
        #expect(corners.allSatisfy { $0 < 64 })

        // Face and plate tracking run on the same frames without finding anything odd.
        var both = FaceTracker.Parameters()
        both.targets = [.faces, .plates]
        let tracks = try await FaceTracker.tracks(in: url, parameters: both, cache: nil)
        print("tracks in \(clock.duration(to: .now))")
        #expect(tracks.allSatisfy { $0.samples.allSatisfy { $0.rect.x >= 0 && $0.rect.x + $0.rect.width <= 1 + 1e-9 } })
    }
}

@Suite("Face tracking", .timeLimit(.minutes(1)))
nonisolated struct FaceTrackerTests {
    @Test func linksOverlappingBoxesIntoTracks() {
        let t = { (i: Int) in Time(value: Int64(i), timescale: 10) }
        let a = Rect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), b = Rect(x: 0.6, y: 0.5, width: 0.2, height: 0.3)
        let moved = Rect(x: 0.12, y: 0.11, width: 0.2, height: 0.2)
        let samples: [(time: Time, rects: [Rect])] = [(t(0), [a, b]), (t(1), [moved, b]), (t(2), [moved]), (t(9), [moved])]
        let tracks = FaceTracker.link(samples, target: .faces, maxGap: Time(value: 3, timescale: 10))
        #expect(tracks.count == 2)
        #expect(tracks[0].samples.map(\.time) == [t(0), t(1), t(2)])
        #expect(tracks[1].samples.count == 2)
    }

    @Test func regionKeyframesFollowTheClip() throws {
        let rate = FrameRate.fps30
        let source = MediaSource(name: "a.mov", kind: .video, duration: Time(value: 10, timescale: 1), frameRate: rate)
        var clip = Clip(
            source: source, range: TimeRange(start: Time(value: 2, timescale: 1), duration: Time(value: 2, timescale: 1)), frameRate: rate)
        clip.start = Time(value: 5, timescale: 1)
        let track = FaceTracker.Track(
            target: .faces,
            samples: [
                .init(time: Time(value: 1, timescale: 1), rect: .full),  // before the clip
                .init(time: Time(value: 2, timescale: 1), rect: Rect(x: 0, y: 0, width: 0.5, height: 0.5)),
                .init(time: Time(value: 3, timescale: 1), rect: Rect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
            ])
        let region = try #require(FaceTracker.region(for: track, in: clip))
        #expect(region.isTracked)
        #expect(region.rect.value(at: .zero) == Rect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(region.rect.value(at: Time(value: 1, timescale: 2)) == Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    @Test func plateText() {
        #expect(FaceTracker.looksLikePlate("ABC 1234"))
        #expect(FaceTracker.looksLikePlate("KA-01-AB-1234") == false)  // too long
        #expect(FaceTracker.looksLikePlate("B MW 123"))
        #expect(!FaceTracker.looksLikePlate("HELLO"))
        #expect(!FaceTracker.looksLikePlate("12345"))
        #expect(abs(FaceTracker.rect(of: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2)).y - 0.1) < 1e-9)
    }
}

@Suite("Reverse", .timeLimit(.minutes(1)))
nonisolated struct ReverseTests {
    @Test func reversedVideoStartsOnTheLastFrame() async throws {
        let folder = try TestMedia.folder()
        let url = try await TestMedia.video(in: folder, seconds: 2, fps: 30, width: 128, height: 64)
        let cache = Fixtures.cache()
        let reversed = try await Reverse.video(of: url, cache: cache)

        let frame = CMTime(value: 1, timescale: 30)
        let duration = try await AVURLAsset(url: url).load(.duration)
        #expect(abs((try await AVURLAsset(url: reversed).load(.duration) - duration).seconds) < 0.034)
        let sourceLast = try await Fixtures.meanLuma(url, at: duration - frame)
        let sourceFirst = try await Fixtures.meanLuma(url, at: .zero)
        #expect(abs(try await Fixtures.meanLuma(reversed, at: .zero) - sourceLast) < 3)
        #expect(abs(try await Fixtures.meanLuma(reversed, at: duration - frame) - sourceFirst) < 3)
        #expect(Reverse.cachedVideo(for: url, cache: cache) == reversed)
    }

    @Test func reversedAudioPlaysBackwards() async throws {
        let folder = try TestMedia.folder()
        let rate = 48_000.0
        let url = try Fixtures.wav(
            Fixtures.sine(seconds: 0.5, rate: rate, amplitude: 0.5) + [Float](repeating: 0, count: 24_000), rate: rate, in: folder)
        let out = try await Fixtures.read(try await Reverse.audio(of: url, cache: Fixtures.cache()), rate: rate)
        #expect(out.count == 48_000)
        #expect(Fixtures.rms(out[1_000..<23_000]) < -80)
        #expect(Fixtures.rms(out[25_000..<47_000]) > -10)
    }

    @Test func cancellingLeavesNothingCached() async throws {
        let folder = try TestMedia.folder()
        let url = try await TestMedia.video(in: folder, seconds: 2, fps: 30, width: 128, height: 64)
        let cache = Fixtures.cache()
        let task = Task { try await Reverse.video(of: url, cache: cache) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Reverse.cachedVideo(for: url, cache: cache) == nil)
        let folderContents =
            (try? FileManager.default.contentsOfDirectory(atPath: cache.root.appending(path: "reverse-video").path(percentEncoded: false)))
            ?? []
        #expect(folderContents.isEmpty)
    }
}

// MARK: - Cache

@Suite("Analysis cache", .timeLimit(.minutes(1)))
nonisolated struct AnalysisCacheTests {
    @Test func secondRunIsAHit() async throws {
        let folder = try TestMedia.folder()
        let media = try TestMedia.tone(in: folder)
        let cache = Fixtures.cache()
        let key = try AnalysisCache.Key("test", media: media, parameters: ["a"])
        let runs = Mutex(0)
        for _ in 0..<2 {
            let value = try await cache.value(key) {
                runs.withLock { $0 += 1 }
                return [1, 2, 3]
            }
            #expect(value == [1, 2, 3])
        }
        #expect(runs.withLock { $0 } == 1)

        // Different parameters or a rewritten file miss.
        #expect(try AnalysisCache.Key("test", media: media, parameters: ["b"]) != key)
        try await Task.sleep(for: .milliseconds(10))
        _ = try TestMedia.tone(in: folder, seconds: 2)
        #expect(try AnalysisCache.Key("test", media: media, parameters: ["a"]) != key)

        let made = Mutex(0)
        for _ in 0..<2 {
            let file = try await cache.file(key, extension: "bin") { url in
                made.withLock { $0 += 1 }
                try Data([1]).write(to: url)
            }
            #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        }
        #expect(made.withLock { $0 } == 1)
        try cache.removeAll()
        #expect(cache.existing(key, extension: "bin") == nil)
    }
}
