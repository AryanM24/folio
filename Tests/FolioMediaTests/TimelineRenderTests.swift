import AVFoundation
import CoreImage
import ImageIO
import Testing

@testable import FolioMedia

// Probe frames come from `AVAssetImageGenerator` with the build's video composition, so
// they go through the same compositor as the player and the exporter.

private let canvas = CanvasSize(width: 320, height: 180)

private func seconds(_ s: Double) -> Time { Time(value: Int64((s * 30).rounded()), timescale: 30) }

private func project(_ tracks: [Track], sources: [MediaSource], settings: ProjectSettings? = nil) -> Project {
    var p = Project(settings: settings ?? ProjectSettings(canvas: canvas, frameRate: .fps30), tracks: tracks)
    p.sources = sources
    return p
}

private func clip(_ source: MediaSource, at start: Double, length: Double, from sourceStart: Double = 0) -> Clip {
    Clip(content: .media(source: source.id), start: seconds(start), duration: seconds(length), sourceStart: seconds(sourceStart))
}

private func track(_ clips: [Clip]) -> Track { track(.video, clips) }

private func track(_ kind: Track.Kind, _ clips: [Clip]) -> Track {
    var t = Track(kind: kind, name: kind.rawValue)
    t.clips = clips
    return t
}

private func frame(_ render: TimelineRender, at s: Double) async throws -> CGImage {
    try await render.makeImageGenerator().image(at: CMTime(value: CMTimeValue((s * 600).rounded()), timescale: 600)).image
}

/// sRGB components at a point given as fractions of the frame, origin top-left.
private nonisolated func pixel(_ image: CGImage, _ x: Double, _ y: Double) -> [Double] {
    let px = min(image.width - 1, Int(x * Double(image.width))), py = min(image.height - 1, Int(y * Double(image.height)))
    var data = [UInt8](repeating: 0, count: 4)
    data.withUnsafeMutableBytes { bytes in
        let context = CGContext(
            data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(
            image, in: CGRect(x: -Double(px), y: -Double(image.height - 1 - py), width: Double(image.width), height: Double(image.height)))
    }
    return data[0..<3].map { Double($0) / 255 }
}

/// Share of pixels brighter than `threshold` in every channel.
private nonisolated func brightShare(_ image: CGImage, threshold: Double = 0.8) -> Double {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { bytes in
        let context = CGContext(
            data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let limit = UInt8(threshold * 255)
    var count = 0
    for i in stride(from: 0, to: data.count, by: 4) where data[i] > limit && data[i + 1] > limit && data[i + 2] > limit { count += 1 }
    return Double(count) / Double(w * h)
}

private func near(_ a: [Double], _ b: [Double], _ tolerance: Double = 0.08) -> Bool {
    zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

// MARK: - Generated media

private nonisolated enum RenderMedia {
    /// A still-picture movie, `color(x, y)` per pixel (fractions, origin top-left), sRGB.
    static func video(
        in folder: URL, name: String, seconds: Double = 2, width: Int = 160, height: Int = 90,
        color: @Sendable (Double, Double) -> (Double, Double, Double)
    ) async throws -> MediaSource {
        let url = folder.appending(path: "\(name).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoQualityKey: 1.0],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color((Double(x) + 0.5) / Double(width), (Double(y) + 0.5) / Double(height))
                let i = (y * width + x) * 4
                (pixels[i], pixels[i + 1], pixels[i + 2]) = (UInt8(b * 255), UInt8(g * 255), UInt8(r * 255))
            }
        }
        for i in 0..<Int(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!, stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height { pixels.withUnsafeBytes { _ = memcpy(base + y * stride, $0.baseAddress! + y * width * 4, width * 4) } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return try await source(url, kind: .video)
    }

    static func solid(in folder: URL, name: String, _ rgb: (Double, Double, Double), seconds: Double = 2) async throws -> MediaSource {
        try await video(in: folder, name: name, seconds: seconds) { _, _ in rgb }
    }

    static func source(_ url: URL, kind: MediaSource.Kind) async throws -> MediaSource {
        let asset = AVURLAsset(url: url)
        let duration = Time(try await asset.load(.duration))
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        var size: CGSize?
        if let video = try await asset.loadTracks(withMediaType: .video).first { size = try await video.load(.naturalSize) }
        return try MediaSource(
            url: url, kind: kind, duration: duration, frameRate: .fps30, width: size.map { Int($0.width) }, height: size.map { Int($0.height) },
            hasAudio: hasAudio)
    }

    /// A 44.1 kHz sine, `left`/`right` amplitudes per channel (one channel when `right` is nil).
    static func tone(in folder: URL, name: String, seconds: Double = 2, left: Float = 0.5, right: Float? = nil) async throws -> MediaSource {
        let url = folder.appending(path: "\(name).wav")
        let rate = 44_100.0
        let channels: AVAudioChannelCount = right == nil ? 1 : 2
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let s = sin(2 * .pi * 440 * Float(i) / Float(rate))
            buffer.floatChannelData![0][i] = left * s
            if let right { buffer.floatChannelData![1][i] = right * s }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ])
        try file.write(from: buffer)
        return try await source(url, kind: .audio)
    }

    static func png(in folder: URL, name: String, _ rgb: (Double, Double, Double)) throws -> MediaSource {
        let url = folder.appending(path: "\(name).png")
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return try MediaSource(url: url, kind: .image, duration: nil, hasAudio: false)
    }
}

/// RMS per channel of the mixed sound over `[t - 0.05, t + 0.05]`, read back through
/// `AVAssetReaderAudioMixOutput` with the build's audio mix.
private func rms(_ render: TimelineRender, at times: [Double]) async throws -> [[Double]] {
    let tracks = UncheckedSendable(try await render.composition.loadTracks(withMediaType: .audio))
    guard !tracks.value.isEmpty else { return times.map { _ in [0, 0] } }
    let samples: [Float] = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do {
                let reader = try AVAssetReader(asset: render.composition)
                let output = AVAssetReaderAudioMixOutput(
                    audioTracks: tracks.value,
                    audioSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                    ])
                output.audioMix = render.audioMix
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
                var all: [Float] = []
                while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                    let length = CMBlockBufferGetDataLength(block)
                    var chunk = [Float](repeating: 0, count: length / 4)
                    chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                    all += chunk
                }
                continuation.resume(returning: all)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    return times.map { t in
        let lo = max(0, Int((t - 0.05) * 44_100)), hi = min(samples.count / 2, Int((t + 0.05) * 44_100))
        return (0..<2).map { c in
            guard hi > lo else { return 0 }
            let sum = (lo..<hi).reduce(0.0) { $0 + Double(samples[$1 * 2 + c] * samples[$1 * 2 + c]) }
            return (sum / Double(hi - lo)).squareRoot()
        }
    }
}

/// Reverse results from a test double of WP4's cache.
private struct FakeAnalysis: RenderAnalysis {
    var reversed: [SourceID: URL] = [:]
    func reversedMedia(for source: MediaSource) -> URL? { reversed[source.id] }
}

// MARK: - Pictures

@Suite(.timeLimit(.minutes(1))) struct TimelineRenderPictureTests {
    @Test func cutsShowEachClip() async throws {
        let folder = try TestMedia.folder()
        let red = try await RenderMedia.solid(in: folder, name: "red", (1, 0, 0))
        let blue = try await RenderMedia.solid(in: folder, name: "blue", (0, 0, 1))
        let p = project([track([clip(red, at: 0, length: 1), clip(blue, at: 1, length: 1)])], sources: [red, blue])
        let render = try await TimelineBuilder.build(p)
        #expect(render.duration == CMTime(value: 2, timescale: 1))
        #expect(render.renderSize == CGSize(width: 320, height: 180))
        #expect(near(pixel(try await frame(render, at: 0.5), 0.5, 0.5), [1, 0, 0]))
        #expect(near(pixel(try await frame(render, at: 1.5), 0.5, 0.5), [0, 0, 1]))
        // Butted clips without a transition share one composition track (plus the empty base track).
        #expect(try await render.composition.loadTracks(withMediaType: .video).count == 2)
    }

    @Test func dissolveMidpointBlendsInLinearLight() async throws {
        let folder = try TestMedia.folder()
        let red = try await RenderMedia.solid(in: folder, name: "red", (1, 0, 0))
        let blue = try await RenderMedia.solid(in: folder, name: "blue", (0, 0, 1))
        var b = clip(blue, at: 1, length: 1, from: 0.5)
        b.transitionIn = ClipTransition(kind: .dissolve, duration: seconds(0.4))
        let p = project([track([clip(red, at: 0, length: 1), b])], sources: [red, blue])
        let render = try await TimelineBuilder.build(p)
        let mid = pixel(try await frame(render, at: 1), 0.5, 0.5)
        // Core Image mixes in linear light: 50 % of red and blue reads ~0.73 in sRGB, not 0.5.
        #expect(near(mid, [0.73, 0, 0.74], 0.07), "\(mid)")
        #expect(near(pixel(try await frame(render, at: 0.7), 0.5, 0.5), [1, 0, 0]))
        #expect(near(pixel(try await frame(render, at: 1.3), 0.5, 0.5), [0, 0, 1]))
        // A/B packing: the overlap needs a second track.
        #expect(try await render.composition.loadTracks(withMediaType: .video).count == 3)
    }

    @Test func wipeRevealsFromTheMotionsSide() async throws {
        let folder = try TestMedia.folder()
        let red = try await RenderMedia.solid(in: folder, name: "red", (1, 0, 0))
        let blue = try await RenderMedia.solid(in: folder, name: "blue", (0, 0, 1))
        var b = clip(blue, at: 1, length: 1, from: 0.5)
        b.transitionIn = ClipTransition(kind: .wipe, duration: seconds(0.4), direction: .left)
        let render = try await TimelineBuilder.build(project([track([clip(red, at: 0, length: 1), b])], sources: [red, blue]))
        let image = try await frame(render, at: 1)
        #expect(near(pixel(image, 0.2, 0.5), [1, 0, 0]))
        #expect(near(pixel(image, 0.8, 0.5), [0, 0, 1]))
    }

    @Test func fadeInFromBlackWithoutNeighbour() async throws {
        let folder = try TestMedia.folder()
        let white = try await RenderMedia.solid(in: folder, name: "white", (1, 1, 1))
        var c = clip(white, at: 0, length: 2)
        c.transitionIn = ClipTransition(kind: .dissolve, duration: seconds(1))
        let render = try await TimelineBuilder.build(project([track([c])], sources: [white]))
        let start = pixel(try await frame(render, at: 0), 0.5, 0.5)[0]
        let half = pixel(try await frame(render, at: 0.5), 0.5, 0.5)[0]
        let after = pixel(try await frame(render, at: 1.5), 0.5, 0.5)[0]
        #expect(start < 0.1 && half > 0.3 && half < 0.9 && after > 0.95, "\(start) \(half) \(after)")
    }

    @Test func pictureInPicture() async throws {
        let folder = try TestMedia.folder()
        let red = try await RenderMedia.solid(in: folder, name: "red", (1, 0, 0))
        let blue = try await RenderMedia.solid(in: folder, name: "blue", (0, 0, 1))
        var inset = clip(red, at: 0, length: 2)
        inset.transform.scale = Keyframed(0.25)
        inset.transform.position = Keyframed(Vec2(x: 0.3, y: -0.3))
        let render = try await TimelineBuilder.build(project([track([clip(blue, at: 0, length: 2)]), track([inset])], sources: [red, blue]))
        let image = try await frame(render, at: 1)
        #expect(near(pixel(image, 0.5, 0.5), [0, 0, 1]))
        #expect(near(pixel(image, 0.8, 0.2), [1, 0, 0]))
        #expect(near(pixel(image, 0.2, 0.8), [0, 0, 1]))
    }

    @Test func cropKeepsTheRestOfThePicture() async throws {
        let folder = try TestMedia.folder()
        let split = try await RenderMedia.video(in: folder, name: "split") { x, _ in x < 0.5 ? (1, 0, 0) : (0, 0, 1) }
        var c = clip(split, at: 0, length: 1)
        #expect(near(pixel(try await frame(try await TimelineBuilder.build(project([track([c])], sources: [split])), at: 0.5), 0.9, 0.5), [0, 0, 1]))
        c.transform.crop = Keyframed(Insets(right: 0.5))
        c.transform.fit = .fill
        let image = try await frame(try await TimelineBuilder.build(project([track([c])], sources: [split])), at: 0.5)
        #expect(near(pixel(image, 0.9, 0.5), [1, 0, 0]))
        #expect(near(pixel(image, 0.1, 0.5), [1, 0, 0]))
    }

    @Test func blurredBackdropFillsTheBars() async throws {
        let folder = try TestMedia.folder()
        let red = try await RenderMedia.solid(in: folder, name: "red", (1, 0, 0))
        var c = clip(red, at: 0, length: 1)
        let settings = ProjectSettings(canvas: CanvasSize(width: 180, height: 320), frameRate: .fps30)
        let bare = try await frame(try await TimelineBuilder.build(project([track([c])], sources: [red], settings: settings)), at: 0.5)
        #expect(near(pixel(bare, 0.5, 0.05), [0, 0, 0]))
        c.transform.backdrop = .blurred(radius: 0.02)
        let filled = try await frame(try await TimelineBuilder.build(project([track([c])], sources: [red], settings: settings)), at: 0.5)
        #expect(pixel(filled, 0.5, 0.05)[0] > 0.8)
        #expect(near(pixel(filled, 0.5, 0.5), [1, 0, 0]))
    }

    @Test func lutMapsAGrayRamp() async throws {
        let folder = try TestMedia.folder()
        let ramp = try await RenderMedia.video(in: folder, name: "ramp") { x, _ in (x, x, x) }
        // out = (r, 0, 1 − r): a 2-point cube, red fastest.
        var cube = "TITLE \"test\"\nLUT_3D_SIZE 2\n"
        for _ in 0..<2 { for _ in 0..<2 { for r in 0..<2 { cube += "\(r) 0 \(1 - r)\n" } } }
        let lutURL = folder.appending(path: "test.cube")
        try Data(cube.utf8).write(to: lutURL)
        var c = clip(ramp, at: 0, length: 1)
        c.effects = [Effect(.lut(LUTReference(name: "test", path: lutURL.path(percentEncoded: false))))]
        let image = try await frame(try await TimelineBuilder.build(project([track([c])], sources: [ramp])), at: 0.5)
        let dark = pixel(image, 0.1, 0.5), light = pixel(image, 0.9, 0.5)
        #expect(dark[0] < 0.35 && dark[1] < 0.1 && dark[2] > 0.7, "\(dark)")
        #expect(light[0] > 0.7 && light[1] < 0.1 && light[2] < 0.35, "\(light)")
    }

    @Test func titleTextIsDrawn() async throws {
        var title = Clip(content: .title(Title(text: "HELLO", style: TextStyle(size: 0.3))), duration: seconds(1))
        title.start = .zero
        let render = try await TimelineBuilder.build(project([track(.title, [title])], sources: []))
        let share = brightShare(try await frame(render, at: 0.5))
        #expect(share > 0.02 && share < 0.5, "\(share)")
    }

    @Test func burnedInCaptionsSitAtTheBottom() async throws {
        let folder = try TestMedia.folder()
        let gray = try await RenderMedia.solid(in: folder, name: "gray", (0.2, 0.2, 0.2))
        var p = project([track([clip(gray, at: 0, length: 2)])], sources: [gray])
        var captions = CaptionTrack()
        captions.style.text = TextStyle(size: 0.15, color: .white)
        captions.cues = [CaptionCue(text: "HELLO", range: TimeRange(start: .zero, duration: seconds(1)))]
        p.captions = [captions]
        let render = try await TimelineBuilder.build(p)
        let shown = try await frame(render, at: 0.5)
        let image = CIImage(cgImage: shown)
        let bottom = CIContext().createCGImage(image, from: CGRect(x: 0, y: 0, width: 320, height: 60))!
        let top = CIContext().createCGImage(image, from: CGRect(x: 0, y: 120, width: 320, height: 60))!
        #expect(brightShare(bottom) > 0.02)
        #expect(brightShare(top) == 0)
        #expect(brightShare(try await frame(render, at: 1.5)) == 0)
    }

    @Test func colorImageAndFreezeClips() async throws {
        let folder = try TestMedia.folder()
        let magenta = try RenderMedia.png(in: folder, name: "magenta", (1, 0, 1))
        let ramp = try await RenderMedia.source(try await TestMedia.video(in: folder, seconds: 2, fps: 30), kind: .video)
        let color = Clip(content: .color(RGBA(red: 0, green: 1, blue: 0)), start: .zero, duration: seconds(1))
        let image = Clip(content: .image(source: magenta.id), start: seconds(1), duration: seconds(1))
        let freeze = Clip(content: .freeze(source: ramp.id, at: seconds(1)), start: seconds(2), duration: seconds(1))
        var fill = image
        fill.transform.fit = .fill
        let render = try await TimelineBuilder.build(project([track([color, fill, freeze])], sources: [magenta, ramp]))
        #expect(near(pixel(try await frame(render, at: 0.5), 0.5, 0.5), [0, 1, 0]))
        #expect(near(pixel(try await frame(render, at: 1.5), 0.5, 0.5), [1, 0, 1]))
        let early = pixel(try await frame(render, at: 2.1), 0.5, 0.5)[0], late = pixel(try await frame(render, at: 2.9), 0.5, 0.5)[0]
        #expect(abs(early - late) < 0.02 && early > 0.35 && early < 0.65, "\(early) \(late)")
    }

    @Test func speedReadsSourceFaster() async throws {
        let folder = try TestMedia.folder()
        // Frame i is gray i/60: the level tells which source frame is shown.
        let ramp = try await RenderMedia.source(try await TestMedia.video(in: folder, seconds: 2, fps: 30), kind: .video)
        var fast = clip(ramp, at: 0, length: 1)
        fast.retime = Retime(speed: Rational(2))
        let render = try await TimelineBuilder.build(project([track([fast])], sources: [ramp]))
        // Half a second in at 2× shows source second 1, as a 1× clip starting there does.
        let level = pixel(try await frame(render, at: 0.5), 0.5, 0.5)[0]
        let plain = try await TimelineBuilder.build(project([track([clip(ramp, at: 0, length: 1, from: 1)])], sources: [ramp]))
        let expected = pixel(try await frame(plain, at: 0), 0.5, 0.5)[0]
        let unsped = pixel(try await frame(plain, at: 0.5), 0.5, 0.5)[0]
        #expect(abs(level - expected) < 0.03 && expected < unsped - 0.1, "\(level) \(expected) \(unsped)")
    }

    @Test func reverseUsesTheAnalysisCopyOrReportsPending() async throws {
        let folder = try TestMedia.folder()
        let forward = try await RenderMedia.solid(in: folder, name: "forward", (1, 0, 0))
        let backward = try await RenderMedia.solid(in: folder, name: "backward", (0, 1, 0))
        var c = clip(forward, at: 0, length: 1)
        c.retime.reversed = true
        let p = project([track([c])], sources: [forward])
        let without = try await TimelineBuilder.build(p)
        #expect(without.pending.contains(PendingAnalysis(source: forward.id, kind: .reverse)))
        var options = RenderOptions()
        options.analysis = FakeAnalysis(reversed: [forward.id: backward.url])
        let with = try await TimelineBuilder.build(p, options: options)
        #expect(with.pending.isEmpty)
        #expect(near(pixel(try await frame(with, at: 0.5), 0.5, 0.5), [0, 1, 0]))
    }

    @Test func chromaKeyAndRedaction() async throws {
        let folder = try TestMedia.folder()
        let red = try await RenderMedia.solid(in: folder, name: "red", (1, 0, 0))
        let green = try await RenderMedia.solid(in: folder, name: "green", (0, 1, 0))
        var keyed = clip(green, at: 0, length: 1)
        keyed.effects = [Effect(.chromaKey(ChromaKey()))]
        var base = clip(red, at: 0, length: 1)
        var region = RedactRegion(rect: Keyframed(Rect(x: 0, y: 0, width: 0.25, height: 0.25)))
        region.style = .fill
        base.effects = [Effect(.redact([region]))]
        let image = try await frame(try await TimelineBuilder.build(project([track([base]), track([keyed])], sources: [red, green])), at: 0.5)
        #expect(near(pixel(image, 0.5, 0.5), [1, 0, 0]))
        #expect(near(pixel(image, 0.1, 0.1), [0, 0, 0]))
    }

    @Test func missingMediaIsLeftOut() async throws {
        let folder = try TestMedia.folder()
        let red = try await RenderMedia.solid(in: folder, name: "red", (1, 0, 0))
        var gone = red
        gone.id = SourceID()
        gone.path = folder.appending(path: "nowhere.mov").path(percentEncoded: false)
        gone.bookmark = nil
        let p = project([track([clip(red, at: 0, length: 1), clip(gone, at: 1, length: 1)])], sources: [red, gone])
        let render = try await TimelineBuilder.build(p)
        #expect(render.missing == [gone.id])
        #expect(near(pixel(try await frame(render, at: 1.5), 0.5, 0.5), [0, 0, 0]))
    }
}

// MARK: - Sound

@Suite(.timeLimit(.minutes(1))) struct TimelineRenderAudioTests {
    @Test func volumeAndFades() async throws {
        let folder = try TestMedia.folder()
        let tone = try await RenderMedia.tone(in: folder, name: "tone", seconds: 2)
        var c = clip(tone, at: 0, length: 2)
        c.audio.volume = Keyframed(0.5)
        c.audio.fadeIn = seconds(0.5)
        let render = try await TimelineBuilder.build(project([track(.video, []), track(.audio, [c])], sources: [tone]))
        let levels = try await rms(render, at: [0.1, 1.0])
        // A 0.5 sine is 0.354 RMS; at half volume 0.177.
        #expect(levels[0][0] < 0.06, "\(levels)")
        #expect(abs(levels[1][0] - 0.177) < 0.03, "\(levels)")
    }

    @Test func crossfadeDucksAndMutes() async throws {
        let folder = try TestMedia.folder()
        let tone = try await RenderMedia.tone(in: folder, name: "tone", seconds: 3)
        var music = track(.audio, [clip(tone, at: 0, length: 3)])
        music.ducking = Ducking(amount: -12, fade: seconds(0.1))
        var options = RenderOptions()
        options.speech = [TimeRange(start: seconds(1), duration: seconds(1))]
        let p = project([track(.video, []), music], sources: [tone])
        let levels = try await rms(try await TimelineBuilder.build(p, options: options), at: [0.5, 1.5])
        #expect(abs(levels[0][0] - 0.354) < 0.04, "\(levels)")
        #expect(abs(levels[1][0] - 0.354 * 0.251) < 0.03, "\(levels)")

        var muted = p
        muted.tracks[1].isMuted = true
        #expect(try await rms(try await TimelineBuilder.build(muted), at: [0.5])[0][0] < 0.001)
        var soloOther = RenderOptions()
        soloOther.soloTracks = [p.tracks[0].id]
        #expect(try await rms(try await TimelineBuilder.build(p, options: soloOther), at: [0.5])[0][0] < 0.001)
    }

    @Test func transitionCrossfadesSound() async throws {
        let folder = try TestMedia.folder()
        let tone = try await RenderMedia.tone(in: folder, name: "tone", seconds: 3)
        var b = clip(tone, at: 1, length: 1, from: 1)
        b.transitionIn = ClipTransition(kind: .dissolve, duration: seconds(0.6))
        let render = try await TimelineBuilder.build(project([track(.video, []), track(.audio, [clip(tone, at: 0, length: 1), b])], sources: [tone]))
        #expect(try await render.composition.loadTracks(withMediaType: .audio).count == 2)
        let levels = try await rms(render, at: [0.5, 1.5])
        #expect(abs(levels[0][0] - 0.354) < 0.04 && abs(levels[1][0] - 0.354) < 0.04, "\(levels)")
    }

    @Test func panMovesStereoSound() async throws {
        let folder = try TestMedia.folder()
        let tone = try await RenderMedia.tone(in: folder, name: "stereo", seconds: 2, left: 0.5, right: 0.5)
        var c = clip(tone, at: 0, length: 2)
        c.audio.pan = Keyframed(1)
        let levels = try await rms(try await TimelineBuilder.build(project([track(.video, []), track(.audio, [c])], sources: [tone])), at: [1])
        #expect(levels[0][0] < 0.02 && levels[0][1] > 0.3, "\(levels)")
    }

    @Test func rampsFollowCurvesWithinOnePercent() {
        var c = Clip(content: .color(.black), duration: seconds(2))
        c.audio.volume.set(0, at: .zero, interpolation: .easeInOut)
        c.audio.volume.set(1, at: seconds(2))
        let piece = AudioMixBuilder.Piece(
            trackID: 1, window: c.range, clip: c, trackVolume: 1, ducking: nil, fadeUp: nil, fadeDown: nil)
        let ramps = AudioMixBuilder.ramps(piece, speech: [])
        #expect(ramps.count > 4)
        #expect(ramps.first?.range.start == .zero && ramps.last?.range.end == seconds(2))
        for r in ramps {
            let mid = (r.range.start + r.range.end) * Rational(1, 2)
            #expect(abs(AudioMixBuilder.gain(piece, at: mid, speech: []) - (r.from + r.to) / 2) <= 0.0101)
        }
    }
}

// MARK: - LUT files and build cost

@Suite(.timeLimit(.minutes(1))) struct TimelineRenderBuildTests {
    @Test func cubeParsing() throws {
        let oneD = try CubeLUT(data: Data("# c\nLUT_1D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n0 0 0\n1 0.5 0.25\n".utf8))
        #expect(oneD.size == 64 && oneD.domainMax == [2, 2, 2] && !oneD.hasUnitDomain)
        #expect(oneD.cube.count == 64 * 64 * 64 * 16)
        let threeD = try CubeLUT(data: Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8))
        #expect(threeD.size == 2 && threeD.hasUnitDomain && threeD.cube.count == 8 * 16)
        #expect(throws: (any Error).self) { try CubeLUT(data: Data("LUT_3D_SIZE 2\n0 0 0\n".utf8)) }
        #expect(throws: (any Error).self) { try CubeLUT(data: Data("LUT_3D_SIZE 129\n".utf8)) }
        #expect(throws: (any Error).self) { try CubeLUT(data: Data("0 0 0\n".utf8)) }
    }

    @Test func tenClipTimelineBuildsQuickly() async throws {
        let folder = try TestMedia.folder()
        let red = try await RenderMedia.solid(in: folder, name: "red", (1, 0, 0), seconds: 4)
        let blue = try await RenderMedia.solid(in: folder, name: "blue", (0, 0, 1), seconds: 4)
        var v1: [Clip] = []
        for i in 0..<5 {
            var c = clip(i.isMultiple(of: 2) ? red : blue, at: Double(i), length: 1, from: 1)
            if i > 0 { c.transitionIn = ClipTransition(kind: .dissolve, duration: seconds(0.4)) }
            v1.append(c)
        }
        let v2 = (0..<5).map { i in
            var t = Clip(content: .title(Title(text: "Title \(i)")), start: seconds(Double(i)), duration: seconds(0.5))
            t.effects = [Effect(.color(ColorAdjustments(exposure: 0.5)))]
            return t
        }
        let p = project([track(v1), track(.title, v2), track(.audio, [])], sources: [red, blue])
        let cold = ContinuousClock.now
        _ = try await TimelineBuilder.build(p)
        let coldTime = cold.duration(to: .now)
        // Best of three, so one scheduling spike under a loaded full-suite run can't fail the budget.
        var render = try await TimelineBuilder.build(p)
        var warmTime = Duration.seconds(1)
        for _ in 0..<3 {
            let warm = ContinuousClock.now
            render = try await TimelineBuilder.build(p)
            warmTime = min(warmTime, warm.duration(to: .now))
        }
        print("10-clip build: cold \(coldTime), warm \(warmTime)")
        #expect(warmTime < .milliseconds(50))
        #expect(render.videoComposition.instructions.count >= 10)
    }

    @Test func threeLayer1080pRendersInRealTime() async throws {
        let folder = try TestMedia.folder()
        let source = try await RenderMedia.source(try await TestMedia.video(in: folder, seconds: 2, fps: 30, width: 1920, height: 1080), kind: .video)
        var pip = clip(source, at: 0, length: 2)
        pip.transform.scale = Keyframed(0.4)
        pip.transform.position.set(Vec2(x: -0.3, y: 0), at: .zero)
        pip.transform.position.set(Vec2(x: 0.3, y: 0), at: seconds(2))
        var graded = clip(source, at: 0, length: 2)
        graded.effects = [Effect(.color(ColorAdjustments(exposure: 0.3, saturation: 1.2)))]
        let title = Clip(content: .title(Title(text: "Folio")), start: .zero, duration: seconds(2))
        let settings = ProjectSettings(canvas: CanvasSize(width: 1920, height: 1080), frameRate: .fps30)
        let render = try await TimelineBuilder.build(project([track([graded]), track([pip]), track(.title, [title])], sources: [source], settings: settings))
        let tracks = UncheckedSendable(try await render.composition.loadTracks(withMediaType: .video))
        let (frames, elapsed): (Int, Duration) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let reader = try AVAssetReader(asset: render.composition)
                    let output = AVAssetReaderVideoCompositionOutput(
                        videoTracks: tracks.value, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    output.videoComposition = render.videoComposition
                    reader.add(output)
                    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
                    let start = ContinuousClock.now
                    var count = 0
                    while output.copyNextSampleBuffer() != nil { count += 1 }
                    continuation.resume(returning: (count, start.duration(to: .now)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let fps = Double(frames) / (Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds))
        print("1080p, 3 layers: \(frames) frames at \(Int(fps)) fps")
        #expect(frames == 60)
        #expect(fps >= 30)
    }
}
