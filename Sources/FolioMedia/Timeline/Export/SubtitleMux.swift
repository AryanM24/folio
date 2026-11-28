import AVFoundation
import FolioKit

/// A chapter in the exported file: it runs until the next one, the last until the end.
nonisolated struct Chapter: Equatable, Sendable {
    var start: Time
    var title: String
}

nonisolated extension Project {
    /// Chapter markers as the export writes them; unnamed ones get "Chapter n".
    var exportChapters: [Chapter] {
        chapters.enumerated().map { i, marker in
            Chapter(start: marker.time, title: marker.name.isEmpty ? "Chapter \(i + 1)" : marker.name)
        }
    }
}

/// Adds soft subtitles and chapters to a finished movie without re-encoding it.
///
/// `AVAssetExportSession` can't add tracks, so this is a remux: every video and audio track
/// is copied sample for sample, plus a tx3g subtitle track (with its language, so players
/// list it) and the chapters as a disabled tx3g text track tied to the video by a
/// `chapterList` association. A timed-metadata chapter track writes fine but AVFoundation
/// never reads it back (research §3.5). Each input pulls on its own queue: one loop feeding
/// them in turn deadlocks on MP4 interleaving.
nonisolated enum SubtitleMux {
    static func mux(
        _ movie: URL, subtitles: [SubtitleCue], language: String = "en-US", chapters: [Chapter], to output: URL, fileType: AVFileType
    ) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        guard let end = Time(duration) else { throw FolioError("Couldn't read the movie's length.") }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        var feeds: [(AVAssetWriterInput, () -> CMSampleBuffer?)] = []
        var anchor: AVAssetWriterInput?

        for type in [AVMediaType.video, .audio] {
            for track in try await asset.loadTracks(withMediaType: type) {
                let (formats, transform, code) = try await track.load(.formatDescriptions, .preferredTransform, .languageCode)
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                out.alwaysCopiesSampleData = false
                let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: formats.first)
                input.transform = transform
                input.languageCode = code
                input.expectsMediaDataInRealTime = false
                guard reader.canAdd(out), writer.canAdd(input) else { throw FolioError("Couldn't copy the movie's tracks.") }
                reader.add(out)
                writer.add(input)
                anchor = anchor ?? input
                feeds.append((input, { out.copyNextSampleBuffer() }))
            }
        }
        guard let anchor else { throw FolioError("The movie has no picture or sound to add subtitles to.") }

        let tag = Locale.Language(identifier: language)
        let iso639 = tag.languageCode?.identifier(.alpha3) ?? "und"
        if !subtitles.isEmpty {
            let format = try textFormat(kCMMediaType_Subtitle)
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
            input.languageCode = iso639
            input.extendedLanguageTag = language
            writer.add(input)
            let spans = subtitles.compactMap { cue -> (String, TimeRange)? in
                let r = TimeRange(start: max(.zero, cue.range.start), end: min(end, cue.range.end))
                return r.isEmpty ? nil : (cue.text, r)
            }
            feeds.append((input, try samples(filled(spans.sorted { $0.1.start < $1.1.start }, until: end), format: format)))
        }
        if !chapters.isEmpty {
            let format = try textFormat(kCMMediaType_Text)
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            input.marksOutputTrackAsEnabled = false
            input.languageCode = iso639
            input.extendedLanguageTag = language
            writer.add(input)
            anchor.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            let sorted = chapters.filter { $0.start < end }.sorted { $0.start < $1.start }
            // The first chapter starts the movie: players have nothing to show before it.
            let spans = sorted.indices.map { i -> (String, TimeRange) in
                let start = i == 0 ? Time.zero : sorted[i].start
                let stop = i + 1 < sorted.count ? sorted[i + 1].start : end
                return (sorted[i].title, TimeRange(start: start, end: stop))
            }
            feeds.append((input, try samples(spans.filter { !$0.1.isEmpty }, format: format)))
        }

        guard reader.startReading() else { throw FolioError("Couldn't read the movie: \(reader.error?.localizedDescription ?? "")") }
        guard writer.startWriting() else { throw FolioError("Couldn't start writing: \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: .zero)
        let watched = UncheckedSendable(writer)
        let cancel = UncheckedSendable(reader)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (i, feed) in feeds.enumerated() {
                    let io = UncheckedSendable(feed)
                    group.addTask { await pump(io, label: "folio.mux.\(i)", writer: watched) }
                }
            }
        } onCancel: {
            cancel.value.cancelReading()
        }
        if Task.isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        guard reader.status != .failed, writer.status == .writing else {
            writer.cancelWriting()
            throw FolioError("Adding subtitles failed: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        await writer.finishWriting()
        // The writer doesn't keep its inputs alive while it finishes: without this, ARC frees them early and it crashes.
        withExtendedLifetime(feeds) {}
        guard writer.status == .completed else {
            throw FolioError("Couldn't finish the movie: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    /// Feeds one input until its source runs dry. A watchdog ends the wait if the writer
    /// fails, because `requestMediaDataWhenReady` then stops calling back.
    private static func pump(
        _ io: UncheckedSendable<(AVAssetWriterInput, () -> CMSampleBuffer?)>, label: String, writer: UncheckedSendable<AVAssetWriter>
    ) async {
        let done = Done()
        let watchdog = Task.detached {
            while !done.isDone {
                if writer.value.status == .failed || writer.value.status == .cancelled { return done.finish() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            done.wait(continuation)
            io.value.0.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                let (input, next) = io.value
                while !done.isDone, input.isReadyForMoreMediaData {
                    guard let buffer = next() else {
                        input.markAsFinished()
                        return done.finish()
                    }
                    guard input.append(buffer) else { return done.finish() }
                }
            }
        }
        watchdog.cancel()
    }

    /// Resumes a waiting pump exactly once, whichever of the pump and the watchdog gets there first.
    private nonisolated final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?

        var isDone: Bool { lock.withLock { finished } }

        func wait(_ c: CheckedContinuation<Void, Never>) {
            let resumeNow = lock.withLock {
                if !finished { continuation = c }
                return finished
            }
            if resumeNow { c.resume() }
        }

        func finish() {
            let c: CheckedContinuation<Void, Never>? = lock.withLock {
                finished = true
                defer { continuation = nil }
                return continuation
            }
            c?.resume()
        }
    }

    /// Cues with empty samples in the gaps, so a cue disappears on time in every player.
    static func filled(_ spans: [(String, TimeRange)], until end: Time) -> [(String, TimeRange)] {
        var out: [(String, TimeRange)] = []
        var cursor = Time.zero
        for (text, range) in spans {
            let start = max(range.start, cursor)
            guard range.end > start else { continue }  // overlapping cues: the earlier one wins
            if start > cursor { out.append(("", TimeRange(start: cursor, end: start))) }
            out.append((text, TimeRange(start: start, end: range.end)))
            cursor = range.end
        }
        if end > cursor, !out.isEmpty { out.append(("", TimeRange(start: cursor, end: end))) }
        return out
    }

    /// The samples for a text track, made up front and handed out one at a time.
    private static func samples(_ spans: [(String, TimeRange)], format: CMFormatDescription) throws -> () -> CMSampleBuffer? {
        var queue = try spans.map { try textSample($0.0, $0.1, format: format) }[...]
        return { queue.popFirst() }
    }

    /// A tx3g sample: a big-endian 16-bit length, then UTF-8.
    private static func textSample(_ text: String, _ range: TimeRange, format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8.prefix(Int(UInt16.max)))
        let bytes = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xff)] + utf8
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw FolioError("Couldn't build a subtitle sample (\(status)).") }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        var timing = CMSampleTimingInfo(duration: range.duration.cmTime, presentationTimeStamp: range.start.cmTime, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw FolioError("Couldn't build a subtitle sample (\(status)).") }
        return sample
    }

    /// White sans-serif, bottom centre: what players show when they don't apply their own style.
    private static func textFormat(_ mediaType: CMMediaType) throws -> CMFormatDescription {
        let white: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255, kCMTextFormatDescriptionColor_Blue: 255,
            kCMTextFormatDescriptionColor_Alpha: 255,
        ]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: [
                kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0, kCMTextFormatDescriptionColor_Blue: 0,
                kCMTextFormatDescriptionColor_Alpha: 255,
            ],
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0, kCMTextFormatDescriptionRect_Bottom: 0,
                kCMTextFormatDescriptionRect_Right: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0, kCMTextFormatDescriptionStyle_Font: 1,
                kCMTextFormatDescriptionStyle_FontFace: 0, kCMTextFormatDescriptionStyle_FontSize: 24,
                kCMTextFormatDescriptionStyle_ForegroundColor: white,
            ],
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: nil, mediaType: mediaType, mediaSubType: kCMTextFormatType_3GText, extensions: extensions as CFDictionary,
            formatDescriptionOut: &format)
        guard status == noErr, let format else { throw FolioError("Couldn't describe the subtitle track (\(status)).") }
        return format
    }
}
