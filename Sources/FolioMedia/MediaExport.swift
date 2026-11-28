import AVFoundation
import FolioKit
import UniformTypeIdentifiers

/// One export: which file, which part of it, which changes, which format.
nonisolated struct ExportRequest: Sendable {
    var source: URL
    var format: ExportFormat
    /// `nil` exports the whole file.
    var range: CMTimeRange?
    var edits = MediaEdits()
}

/// Produces new files from a source. Never writes to the source.
///
/// Output goes to a temporary file in the destination's volume and is swapped in only
/// when complete, so a cancelled or failed export never leaves a half-written file and
/// never replaces an existing one.
nonisolated enum MediaExport {
    private static let log = Log.make("Media")

    /// The container the export will actually use. Passthrough can only write containers
    /// that hold the source's codecs (an MP3 can't go in a WAVE file), so this asks
    /// AVFoundation and falls back to QuickTime or M4A. Call before showing a save panel.
    static func fileType(for request: ExportRequest) async -> AVFileType {
        let preferred = request.format.fileType(source: UTType(filenameExtension: request.source.pathExtension))
        guard let presetName = request.format.preset else { return preferred }
        let asset = AVURLAsset(url: request.source)
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else { return preferred }
        let supported = session.supportedFileTypes
        if supported.contains(preferred) || supported.isEmpty { return preferred }
        return [.mov, .m4a, .mp4].first(where: supported.contains) ?? supported[0]
    }

    /// Runs the export, reporting progress 0…1. Throws `CancellationError` when the
    /// calling task is cancelled; the destination is then left untouched.
    static func run(_ request: ExportRequest, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await writeAtomically(to: destination) { temp in
            let (asset, timeRange, metadata) = try await prepare(request)
            if request.format == .wav {
                try await writeWAV(from: asset, range: timeRange, to: temp, progress: progress)
            } else {
                try await exportSession(asset: asset, request: request, range: timeRange, metadata: metadata, to: temp, progress: progress)
            }
        }
        log.info("Exported \(destination.lastPathComponent, privacy: .private) as \(request.format.rawValue, privacy: .public)")
    }

    /// Lets `write` produce a file at a temporary URL on the destination's volume, then
    /// swaps it in. A failed or cancelled write leaves `destination` as it was.
    static func writeAtomically(to destination: URL, _ write: (URL) async throws -> Void) async throws {
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appending(path: destination.lastPathComponent)
        try await write(temp)
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }

    /// The asset to export plus the range of it to use. Without edits the source asset is
    /// exported directly, which keeps chapters, subtitles and all metadata. With edits it
    /// builds a composition; the source's metadata is copied onto the output separately.
    static func prepare(_ request: ExportRequest) async throws -> (AVAsset, CMTimeRange?, [AVMetadataItem]) {
        let source = AVURLAsset(url: request.source)
        let duration = try await source.load(.duration)
        let range = request.range.flatMap { MediaMath.clamp($0, to: duration) }
        let audioTracks = try await source.loadTracks(withMediaType: .audio)
        let videoTracks = try await source.loadTracks(withMediaType: .video)
        let edits = request.edits

        if request.format.isAudioOnly {
            guard !audioTracks.isEmpty else { throw FolioError("This file has no sound to export.") }
            guard !edits.removeAudio else {
                throw FolioError("Audio is removed in Edits, so there's nothing to export. Turn “Remove audio” off and try again.")
            }
        }
        if edits.removeAudio, videoTracks.isEmpty {
            throw FolioError("This file is audio only, so removing the audio would leave nothing.")
        }
        guard !edits.isIdentity else { return (source, range, []) }

        let composition = AVMutableComposition()
        let span = range ?? CMTimeRange(start: .zero, duration: duration)
        for track in videoTracks {
            let (natural, preferred) = try await track.load(.naturalSize, .preferredTransform)
            guard let out = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            try out.insertTimeRange(span, of: track, at: .zero)
            out.preferredTransform = MediaMath.transform(natural: natural, preferred: preferred, edits: edits)
        }
        if !edits.removeAudio {
            for track in audioTracks {
                guard let out = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    continue
                }
                try out.insertTimeRange(span, of: track, at: .zero)
            }
        }
        if edits.speed != 1 {
            let whole = CMTimeRange(start: .zero, duration: composition.duration)
            composition.scaleTimeRange(whole, toDuration: MediaMath.scaled(whole.duration, speed: edits.speed))
        }
        let metadata = (try? await source.load(.metadata)) ?? []
        return (composition, nil, metadata)
    }

    private static func exportSession(
        asset: AVAsset, request: ExportRequest, range: CMTimeRange?, metadata: [AVMetadataItem],
        to url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Passthrough can't retime audio; fall back to the best re-encode for speed changes.
        var presetName = request.format.preset ?? AVAssetExportPresetPassthrough
        if presetName == AVAssetExportPresetPassthrough, request.edits.requiresReencode {
            presetName = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw FolioError("This file can't be exported as \(request.format.title).")
        }
        if let range { session.timeRange = range }
        if !metadata.isEmpty { session.metadata = metadata }
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true
        let fileType = await fileType(for: request)
        guard await AVAssetExportSession.compatibility(ofExportPreset: presetName, with: asset, outputFileType: fileType) else {
            throw FolioError("This file can't be exported as \(request.format.title).")
        }

        // `states(updateInterval:)` exists to be observed while `export` runs; the SDK just
        // doesn't mark the session Sendable yet.
        let observed = UncheckedSendable(session)
        let watcher = Task {
            for await state in observed.value.states(updateInterval: 0.1) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: url, as: fileType)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("Export failed: \(error.localizedDescription, privacy: .public)")
            throw FolioError("The export didn't finish: \(error.localizedDescription)")
        }
        progress(1)
    }

    /// WAV via a reader/writer pair: decode to 16-bit PCM and write a WAVE file.
    /// Runs synchronously on a background thread; the loop checks for cancellation.
    private static func writeWAV(
        from asset: AVAsset, range: CMTimeRange?, to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let first = tracks.first else { throw FolioError("This file has no sound to export.") }
        let asbd = try await first.load(.formatDescriptions).first?.audioStreamBasicDescription
        let duration: CMTime
        if let range { duration = range.duration } else { duration = try await asset.load(.duration) }
        let sampleRate = asbd.map { $0.mSampleRate > 0 ? $0.mSampleRate : 44_100 } ?? 44_100
        let channels = min(2, max(1, Int(asbd?.mChannelsPerFrame ?? 2)))

        let pcm: [String: any Sendable] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcm)
        output.audioTimePitchAlgorithm = .spectral
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else {
            throw FolioError("Couldn't convert the audio: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        let start = range?.start ?? .zero
        writer.startSession(atSourceTime: start)
        // A sped-up composition is already retimed, so its duration is the output's.
        let total = duration.seconds
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); writer.cancelWriting(); throw CancellationError() }
            // A failed writer never becomes ready again: stop instead of waiting forever.
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard writer.status == .writing, input.append(buffer) else { break }
            if total > 0 { progress(min(1, (buffer.presentationTimeStamp - start).seconds / total)) }
        }
        input.markAsFinished()
        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw FolioError("Couldn't convert the audio: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FolioError("Couldn't write the WAV file: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        progress(1)
    }
}

/// Carries a value the SDK hasn't annotated across a task boundary. Use only where the
/// API is documented as safe to call concurrently.
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
