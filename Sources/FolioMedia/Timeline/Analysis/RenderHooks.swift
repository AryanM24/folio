import AVFoundation
import CoreImage
import Synchronization

/// The renderer's view of the analysis cache: what's ready for a source, never computing
/// anything. Pass it as `RenderOptions.analysis`; whatever is missing shows up in
/// `TimelineRender.pending` for the UI to start (and to show "Analysing…").
nonisolated struct CachedAnalysis: RenderAnalysis {
    var cache = AnalysisCache.shared

    func reversedMedia(for source: MediaSource) -> URL? { Reverse.cachedMedia(for: source.url, cache: cache) }

    func voiceIsolatedAudio(for source: MediaSource) -> URL? { VoiceIsolation.cachedFile(for: source.url, cache: cache) }

    func masks(for source: MediaSource, subject: BackgroundSubject) -> (any FrameMasks)? {
        var parameters = Segmentation.Parameters()
        parameters.subject = subject
        return Segmentation.cachedMaskMovie(for: source.url, parameters: parameters, cache: cache).map { MaskMovie(url: $0) }
    }

    func cameraPath(for source: MediaSource) -> (any CameraPath)? {
        guard let path = Stabilizer.cachedPath(for: source.url, strength: 1, cache: cache),
            let width = source.width, let height = source.height
        else { return nil }
        return PixelCameraPath(path: path, size: CGSize(width: width, height: height))
    }
}

/// A stabilization path in the renderer's terms: source pixels, y up. The effect applies its
/// own zoom, so only the translation is handed over.
nonisolated struct PixelCameraPath: CameraPath {
    let path: StabilizationPath
    /// The source's upright display size.
    let size: CGSize

    func correction(at sourceTime: Time) -> CGAffineTransform {
        let o = path.offset(at: sourceTime)
        return CGAffineTransform(translationX: o.x * size.width, y: -o.y * size.height)
    }
}

/// Reads a mask movie frame by frame. Playback and export ask for times in order, so one
/// reader is kept open and stepped forward; a jump back (or far ahead) reopens it.
nonisolated final class MaskMovie: FrameMasks, Sendable {
    let url: URL
    private let state = Mutex<UncheckedSendable<Cursor>?>(nil)

    private final class Cursor {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let start: Time
        var current: (time: Time, image: CIImage)?
        var next: (time: Time, image: CIImage)?

        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, start: Time) {
            self.reader = reader
            self.output = output
            self.start = start
        }
    }

    init(url: URL) { self.url = url }

    func mask(at sourceTime: Time) -> CIImage? {
        state.withLock { slot in
            if let cursor = slot?.value, cursor.start <= sourceTime,
                cursor.current.map({ sourceTime - $0.time < Time(value: 2, timescale: 1) }) ?? true,
                let image = Self.advance(cursor, to: sourceTime)
            {
                return image
            }
            guard let cursor = open(at: sourceTime) else { return nil }
            slot = UncheckedSendable(cursor)
            return Self.advance(cursor, to: sourceTime)
        }
    }

    /// The frame showing at `time`: the last one starting at or before it.
    private static func advance(_ cursor: Cursor, to time: Time) -> CIImage? {
        while true {
            if cursor.next == nil { cursor.next = read(cursor) }
            guard let next = cursor.next, next.time <= time else { break }
            cursor.current = next
            cursor.next = nil
        }
        if let current = cursor.current { return current.image }
        return cursor.next?.image  // before the first frame: the first frame
    }

    /// The next frame's luma as an 8-bit grey image, with no colour conversion on the way.
    private static func read(_ cursor: Cursor) -> (time: Time, image: CIImage)? {
        guard let sample = cursor.output.copyNextSampleBuffer(), let pixels = sample.imageBuffer,
            let time = Time(sample.presentationTimeStamp)
        else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let data = Data(bytes: base, count: row * height)
        let size = CGSize(width: width, height: height)
        return (time, CIImage(bitmapData: data, bytesPerRow: row, size: size, format: .L8, colorSpace: nil))
    }

    private func open(at time: Time) -> Cursor? {
        let asset = AVURLAsset(url: url)
        // shortcut: the synchronous track list (deprecated) because the renderer asks
        // synchronously; mask movies are small local one-track files, so it is quick.
        guard let track = asset.tracks(withMediaType: .video).first, let reader = Self.reader(asset) else { return nil }
        // Start a little early so the frame showing at the time is included.
        let from = max(.zero, time - Time(value: 1, timescale: 2))
        reader.timeRange = CMTimeRange(start: from.cmTime, duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        reader.add(output)
        guard reader.startReading() else { return nil }
        return Cursor(reader: reader, output: output, start: from)
    }

    private static func reader(_ asset: AVAsset) -> AVAssetReader? {
        do { return try AVAssetReader(asset: asset) } catch { return nil }
    }
}
