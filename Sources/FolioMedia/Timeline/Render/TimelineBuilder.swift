import AVFoundation
import CoreImage
import FolioKit
import ImageIO
import Synchronization

/// What an analysis pass (WP4's `AnalysisCache`) has ready for a source. The builder only
/// asks; anything not ready plays unprocessed and is listed in `TimelineRender.pending`.
/// Every method defaults to "not ready".
nonisolated protocol RenderAnalysis: Sendable {
    /// The whole source played backwards, same duration (Reverse).
    func reversedMedia(for source: MediaSource) -> URL?
    /// The source's sound through Voice Isolation, same duration.
    func voiceIsolatedAudio(for source: MediaSource) -> URL?
    /// A temporally denoised copy, same duration.
    func denoisedMedia(for source: MediaSource, strength: Double) -> URL?
    /// A lighter copy for preview, same duration and frame rate.
    func proxy(for source: MediaSource) -> URL?
    func masks(for source: MediaSource, subject: BackgroundSubject) -> (any FrameMasks)?
    func cameraPath(for source: MediaSource) -> (any CameraPath)?
}

nonisolated extension RenderAnalysis {
    func reversedMedia(for source: MediaSource) -> URL? { nil }
    func voiceIsolatedAudio(for source: MediaSource) -> URL? { nil }
    func denoisedMedia(for source: MediaSource, strength: Double) -> URL? { nil }
    func proxy(for source: MediaSource) -> URL? { nil }
    func masks(for source: MediaSource, subject: BackgroundSubject) -> (any FrameMasks)? { nil }
    func cameraPath(for source: MediaSource) -> (any CameraPath)? { nil }
}

nonisolated struct RenderOptions: Sendable {
    /// Render size relative to the canvas: 1 for export, 0.5 for a lighter preview.
    var scale = 1.0
    var analysis: (any RenderAnalysis)?
    /// Preview with `RenderAnalysis.proxy` copies where they exist.
    var useProxies = false
    /// When not empty, only these tracks are heard (a monitoring state, not saved).
    var soloTracks: Set<TrackID> = []
    /// Timeline ranges with speech, for ducking. `nil` takes them from the transcripts.
    var speech: [TimeRange]?
    var burnInCaptions = true

    init() {}
}

/// Analysis a clip asked for that isn't ready, so it renders without it for now.
nonisolated struct PendingAnalysis: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case reverse, voiceIsolation, denoise, stabilization
        case backgroundRemoval(BackgroundSubject)
    }
    var source: SourceID
    var kind: Kind
}

/// A built timeline: the same three objects drive the player, the exporter, the image
/// generator and `AVAssetReader` outputs, so preview and export can't disagree.
///
/// The objects are immutable copies (`AVComposition`, not the mutable builder), which
/// AVFoundation allows sharing across threads; the SDK just doesn't mark them `Sendable`.
nonisolated struct TimelineRender: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix
    let duration: CMTime
    let renderSize: CGSize
    let pending: Set<PendingAnalysis>
    /// Sources that couldn't be found; their clips are left out.
    let missing: Set<SourceID>

    @MainActor func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }

    /// Exact frames (zero tolerance), as drawn by the compositor.
    func makeImageGenerator() -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: composition)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }
}

/// Builds a `TimelineRender` from a `Project`.
///
/// - Media clips become time ranges on as few composition tracks as possible (greedy
///   interval packing, as in Apple's AVCustomEdit): each overlapping track holds a decoder.
///   Transitions overlap the clips on each side by half their length (handles), so the
///   two sides land on different tracks.
/// - Speed changes are one `scaleTimeRange` per constant-speed piece of `Clip.timeMap()`;
///   holds and freeze frames scale a single frame.
/// - Images, colours and titles aren't media: the compositor draws them from the instruction.
/// - A `FrameInstruction` covers each span where the set of layers is constant.
///
/// Opened assets and decoded stills are cached across builds, so a rebuild after an edit
/// costs milliseconds.
nonisolated final class TimelineBuilder: Sendable {
    static let shared = TimelineBuilder()
    private static let log = Log.make("Timeline")

    static func build(_ project: Project, options: RenderOptions = RenderOptions()) async throws -> TimelineRender {
        try await shared.build(project, options: options)
    }

    private let media = Mutex<[String: LoadedMedia]>([:])
    private let stills = Mutex<[String: UncheckedSendable<CIImage>]>([:])

    struct LoadedMedia: @unchecked Sendable {
        /// Kept alive: a track doesn't hold on to its asset.
        var asset: AVURLAsset
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        var orientation: CGAffineTransform
        var duration: Time
    }

    /// A stretch of media at a place on the timeline.
    private struct Segment {
        var track: AVAssetTrack
        var source: TimeRange
        var timeline: TimeRange
    }

    private struct VisualPiece {
        var trackIndex: Int
        var window: TimeRange
        var clip: Clip
        var source: MediaSource?
        var segments: [Segment] = []
        var orientation = CGAffineTransform.identity
        var content: RenderLayer.Content?
        var transitionIn: (ClipTransition, TimeRange, matched: Bool)?
        var transitionOut: (ClipTransition, TimeRange)?
    }

    private struct AudioPiece {
        var segments: [Segment]
        var mix: AudioMixBuilder.Piece
        var pitch: AVAudioTimePitchAlgorithm
    }

    func build(_ project: Project, options: RenderOptions = RenderOptions()) async throws -> TimelineRender {
        let clock = ContinuousClock.now
        let settings = project.settings
        let frame = project.frameDuration
        var pending = Set<PendingAnalysis>()
        var missing = Set<SourceID>()
        var visual: [VisualPiece] = []
        var audio: [AudioPiece] = []
        var images: [SourceID: UncheckedSendable<CIImage>] = [:]
        var luts: [String: CubeLUT] = [:]
        var masks: [String: any FrameMasks] = [:]
        var paths: [SourceID: any CameraPath] = [:]
        let analysis = options.analysis

        for (index, track) in project.tracks.enumerated() {
            let sees = track.kind.isVisual && !track.isHidden
            let hears = !track.isMuted && (options.soloTracks.isEmpty || options.soloTracks.contains(track.id))
            guard sees || hears else { continue }
            let clips = track.clips
            for (i, clip) in clips.enumerated() where clip.isEnabled {
                let previous = i > 0 && clips[i - 1].isEnabled && clips[i - 1].end == clip.start ? clips[i - 1] : nil
                let next = i + 1 < clips.count && clips[i + 1].isEnabled && clips[i + 1].start == clip.end ? clips[i + 1] : nil
                // Butted transitions sit on the right clip and are centred on the cut; others play inside the clip.
                var transitionIn: (ClipTransition, TimeRange, matched: Bool)?
                if let t = clip.transitionIn, t.duration > .zero {
                    let half = t.duration * Rational(1, 2)
                    transitionIn =
                        previous != nil
                        ? (t, TimeRange(start: clip.start - half, duration: t.duration), true)
                        : (t, TimeRange(start: clip.start, duration: min(t.duration, clip.duration)), false)
                }
                var transitionOut: (ClipTransition, TimeRange)?
                if next == nil, let t = clip.transitionOut, t.duration > .zero {
                    let d = min(t.duration, clip.duration)
                    transitionOut = (t, TimeRange(start: clip.end - d, duration: d))
                }
                let lead = transitionIn?.matched == true ? transitionIn!.0.duration * Rational(1, 2) : .zero
                let tail = next?.transitionIn.map { $0.duration > .zero ? $0.duration * Rational(1, 2) : .zero } ?? .zero
                let window = TimeRange(start: clip.start - lead, end: clip.end + tail)

                let source = clip.sourceID.flatMap(project.source)
                var loaded: LoadedMedia?
                var url: URL?
                if let source {
                    switch source.resolve() {
                    case .found(let u), .moved(let u), .changed(let u): url = u
                    case .missing:
                        missing.insert(source.id)
                        continue
                    }
                }

                // Picture.
                if sees {
                    var piece = VisualPiece(
                        trackIndex: index, window: window, clip: clip, source: source, transitionIn: transitionIn,
                        transitionOut: transitionOut)
                    switch clip.content {
                    case .color(let color): piece.content = .color(color)
                    case .title(let title): piece.content = .title(title)
                    case .image(let id):
                        guard let source, let url else { continue }
                        if images[id] == nil, let still = still(url, source: source, canvas: settings.canvas) { images[id] = still }
                        piece.content = .image(id)
                    case .freeze(_, let at):
                        guard let source, let url else { continue }
                        loaded = try? await load(url, source: source)
                        guard let m = loaded, let track = m.video else { break }
                        let start = max(.zero, min(at, m.duration - frame))
                        piece.segments = [Segment(track: track, source: TimeRange(start: start, duration: frame), timeline: window)]
                        piece.orientation = m.orientation
                    case .media:
                        guard let source, let url else { continue }
                        var pictureURL = url
                        var layerClip = clip
                        for case .denoise(let strength) in clip.effects.filter(\.isEnabled).map(\.kind) {
                            if let denoised = analysis?.denoisedMedia(for: source, strength: strength) {
                                pictureURL = denoised
                                layerClip.effects.removeAll { if case .denoise = $0.kind { true } else { false } }
                            } else {
                                pending.insert(PendingAnalysis(source: source.id, kind: .denoise))
                            }
                        }
                        if options.useProxies, let proxy = analysis?.proxy(for: source) { pictureURL = proxy }
                        loaded = try? await load(url, source: source)
                        let picture = pictureURL == url ? loaded : try? await load(pictureURL, source: source)
                        guard let m = picture, m.video != nil else { break }
                        let reversed = await reversedMedia(clip, source: source, analysis: analysis, pending: &pending)
                        piece.segments = segments(clip.reframed(to: window, keepEdges: true), media: m, reversed: reversed, sound: false, frame: frame)
                        piece.orientation = m.orientation
                        piece.clip = layerClip
                    }
                    // Analysis results the effect stack reads per frame.
                    if let source {
                        for kind in clip.effects.filter(\.isEnabled).map(\.kind) {
                            switch kind {
                            case .removeBackground(let subject):
                                let key = RenderScene.maskKey(source.id, subject)
                                if masks[key] == nil {
                                    if let found = analysis?.masks(for: source, subject: subject) {
                                        masks[key] = found
                                    } else {
                                        pending.insert(PendingAnalysis(source: source.id, kind: .backgroundRemoval(subject)))
                                    }
                                }
                            case .stabilize:
                                if paths[source.id] == nil {
                                    if let found = analysis?.cameraPath(for: source) {
                                        paths[source.id] = found
                                    } else {
                                        pending.insert(PendingAnalysis(source: source.id, kind: .stabilization))
                                    }
                                }
                            default: break
                            }
                        }
                    }
                    for case .lut(let reference) in clip.effects.filter(\.isEnabled).map(\.kind) where luts[reference.path] == nil {
                        do {
                            luts[reference.path] = try CubeLUT(contentsOf: URL(filePath: reference.path))
                        } catch {
                            Self.log.error("Couldn't read LUT \(reference.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    if piece.content != nil || !piece.segments.isEmpty { visual.append(piece) }
                }

                // Sound.
                guard hears, clip.audio.isEnabled, case .media = clip.content, let source, let url,
                    track.kind == .audio || source.hasAudio || source.kind == .audio
                else { continue }
                var soundURL = url
                if clip.audio.isolateVoice {
                    if let isolated = analysis?.voiceIsolatedAudio(for: source) {
                        soundURL = isolated
                    } else {
                        pending.insert(PendingAnalysis(source: source.id, kind: .voiceIsolation))
                    }
                }
                if loaded == nil { loaded = try? await load(url, source: source) }
                guard let m = soundURL == url ? loaded : try? await load(soundURL, source: source), m.audio != nil else { continue }
                let reversed = await reversedMedia(clip, source: source, analysis: analysis, pending: &pending)
                let pieces = segments(clip.reframed(to: window, keepEdges: true), media: m, reversed: reversed, sound: true, frame: frame)
                guard !pieces.isEmpty else { continue }
                let mix = AudioMixBuilder.Piece(
                    trackID: kCMPersistentTrackID_Invalid, window: window, clip: clip, trackVolume: track.volume, ducking: track.ducking,
                    fadeUp: transitionIn?.1, fadeDown: transitionOut?.1 ?? next?.transitionIn.flatMap { t in
                        t.duration > .zero ? TimeRange(start: clip.end - t.duration * Rational(1, 2), duration: t.duration) : nil
                    })
                let pitch: AVAudioTimePitchAlgorithm = clip.retime.preservesPitch || clip.retime.isIdentity ? .spectral : .varispeed
                audio.append(AudioPiece(segments: pieces, mix: mix, pitch: pitch))
            }
        }

        // Pack onto composition tracks, earliest first, reusing any track that's free by then.
        let composition = AVMutableComposition()
        var videoPool: [(track: AVMutableCompositionTrack, end: Time)] = []
        var audioPool: [(track: AVMutableCompositionTrack, end: Time, pitch: AVAudioTimePitchAlgorithm)] = []
        for i in visual.indices.sorted(by: { visual[$0].window.start < visual[$1].window.start }) where !visual[i].segments.isEmpty {
            let piece = visual[i]
            let slot =
                videoPool.firstIndex { $0.end <= piece.window.start }
                ?? {
                    videoPool.append((composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!, .zero))
                    return videoPool.count - 1
                }()
            do {
                try insert(piece.segments, into: videoPool[slot].track)
                videoPool[slot].end = piece.window.end
                visual[i].content = .track(videoPool[slot].track.trackID, orientation: piece.orientation)
            } catch {
                Self.log.error("Couldn't place a clip's picture: \(error.localizedDescription, privacy: .public)")
            }
        }
        var mixPieces: [AudioMixBuilder.Piece] = []
        var audioTracks: [CMPersistentTrackID: AVMutableCompositionTrack] = [:]
        var pitches: [CMPersistentTrackID: AVAudioTimePitchAlgorithm] = [:]
        for piece in audio.sorted(by: { $0.mix.window.start < $1.mix.window.start }) {
            let slot =
                audioPool.firstIndex { $0.end <= piece.mix.window.start && $0.pitch == piece.pitch }
                ?? {
                    audioPool.append(
                        (composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!, .zero, piece.pitch))
                    return audioPool.count - 1
                }()
            do {
                try insert(piece.segments, into: audioPool[slot].track)
                audioPool[slot].end = piece.mix.window.end
                var mix = piece.mix
                mix.trackID = audioPool[slot].track.trackID
                mixPieces.append(mix)
                audioTracks[mix.trackID] = audioPool[slot].track
                pitches[mix.trackID] = piece.pitch
            } catch {
                Self.log.error("Couldn't place a clip's sound: \(error.localizedDescription, privacy: .public)")
            }
        }

        var duration = project.duration
        if let longest = Time(composition.duration), longest > duration { duration = longest }
        guard duration > .zero else { throw FolioError("There's nothing on the timeline to play yet.") }
        // An empty track spanning the timeline, so frames are drawn where no media plays.
        composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertEmptyTimeRange(TimeRange(start: .zero, duration: duration).cmTimeRange)

        let captions =
            options.burnInCaptions
            ? project.captions.filter { $0.isEnabled && $0.burnIn }.map { (style: $0.style, cues: project.resolvedCues($0)) } : []
        let scene = RenderScene(
            canvas: settings.canvas, background: settings.background, colorSpace: settings.colorSpace, images: images, luts: luts,
            captions: captions, masks: masks, cameraPaths: paths)
        let instructions = Self.instructions(visual, duration: duration, scene: scene)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = settings.colorSpace.isHDR ? HDRCompositor.self : Compositor.self
        videoComposition.frameDuration = project.frameRate.cmFrameDuration
        let scale = min(1, max(0.1, options.scale))
        videoComposition.renderSize = CGSize(
            width: max(2, Int(Double(settings.canvas.width) * scale) / 2 * 2), height: max(2, Int(Double(settings.canvas.height) * scale) / 2 * 2))
        videoComposition.instructions = instructions
        (videoComposition.colorPrimaries, videoComposition.colorTransferFunction, videoComposition.colorYCbCrMatrix) =
            settings.colorSpace.videoColorProperties

        let speech = options.speech ?? Self.speech(in: project)
        let audioMix = AudioMixBuilder.mix(mixPieces, tracks: audioTracks, speech: speech, pitch: pitches)

        let render = TimelineRender(
            composition: composition.copy() as! AVComposition,
            videoComposition: videoComposition.copy() as! AVVideoComposition,
            audioMix: audioMix.copy() as! AVAudioMix,
            duration: duration.cmTime, renderSize: videoComposition.renderSize, pending: pending, missing: missing)
        let elapsed = clock.duration(to: .now)
        Self.log.debug(
            "Built \(visual.count + audio.count, privacy: .public) pieces on \(videoPool.count + audioPool.count, privacy: .public) tracks, \(instructions.count, privacy: .public) instructions in \(elapsed, privacy: .public)"
        )
        return render
    }

    // MARK: Media

    private func load(_ url: URL, source: MediaSource) async throws -> LoadedMedia {
        let key = "\(url.path(percentEncoded: false))|\(source.fingerprint.size)|\(source.fingerprint.modified)"
        if let hit = media.withLock({ $0[key] }) { return hit }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)
        let orientation = try await video?.load(.preferredTransform) ?? .identity
        let loaded = LoadedMedia(asset: asset, video: video, audio: audio, orientation: orientation, duration: Time(duration) ?? .zero)
        media.withLock {
            if $0.count > 64 { $0.removeAll() }
            $0[key] = loaded
        }
        return loaded
    }

    /// The reversed copy for a reversed clip, or `nil` (and pending) until analysis makes it.
    private func reversedMedia(
        _ clip: Clip, source: MediaSource, analysis: (any RenderAnalysis)?, pending: inout Set<PendingAnalysis>
    ) async -> LoadedMedia? {
        guard clip.retime.reversed else { return nil }
        if let url = analysis?.reversedMedia(for: source), let m = try? await load(url, source: source) { return m }
        pending.insert(PendingAnalysis(source: source.id, kind: .reverse))
        return nil
    }

    /// A still decoded once, upright, at most twice the canvas's long edge (room for Ken Burns).
    private func still(_ url: URL, source: MediaSource, canvas: CanvasSize) -> UncheckedSendable<CIImage>? {
        let limit = min(8192, 2 * max(canvas.width, canvas.height))
        let key = "\(url.path(percentEncoded: false))|\(source.fingerprint.modified)|\(limit)"
        if let hit = stills.withLock({ $0[key] }) { return hit }
        guard let file = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                file, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: limit, kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else {
            Self.log.error("Couldn't decode image \(url.lastPathComponent, privacy: .private)")
            return nil
        }
        let still = UncheckedSendable(CIImage(cgImage: image))
        stills.withLock {
            if $0.count > 32 { $0.removeAll() }
            $0[key] = still
        }
        return still
    }

    /// A clip's time map as media segments. Pieces outside the media are trimmed; holds
    /// become one frame; reversed pieces read the reversed copy (or, without one, play
    /// forwards for the picture and stay silent). Sound above 4× is muted, as iMovie does.
    private func segments(_ clip: Clip, media: LoadedMedia, reversed: LoadedMedia?, sound: Bool, frame: Time) -> [Segment] {
        var result: [Segment] = []
        for piece in clip.timeMap() {
            let hold = piece.speed == .zero
            if sound && (hold || piece.speed.doubleValue > 4) { continue }
            var m = media
            var source = piece.source
            if piece.reversed {
                if let reversed {
                    m = reversed
                    source = TimeRange(start: reversed.duration - source.end, end: reversed.duration - source.start)
                } else if sound {
                    continue
                }
            }
            guard let track = sound ? m.audio : m.video else { return [] }
            var timeline = piece.timeline
            if hold {
                source = TimeRange(start: max(.zero, min(source.start, m.duration - frame)), duration: frame)
            } else {
                guard let valid = source.intersection(TimeRange(start: .zero, duration: m.duration)) else { continue }
                if valid != source {
                    timeline = TimeRange(
                        start: timeline.start + (valid.start - source.start) / piece.speed,
                        end: timeline.end - (source.end - valid.end) / piece.speed)
                    source = valid
                }
            }
            if timeline.duration > .zero { result.append(Segment(track: track, source: source, timeline: timeline)) }
        }
        return result
    }

    private func insert(_ segments: [Segment], into track: AVMutableCompositionTrack) throws {
        for s in segments {
            try track.insertTimeRange(s.source.cmTimeRange, of: s.track, at: s.timeline.start.cmTime)
            if s.source.duration != s.timeline.duration {
                track.scaleTimeRange(
                    CMTimeRange(start: s.timeline.start.cmTime, duration: s.source.duration.cmTime), toDuration: s.timeline.duration.cmTime)
            }
        }
    }

    // MARK: Instructions

    /// One instruction per span with a constant set of layers, covering `0..<duration`.
    private static func instructions(_ pieces: [VisualPiece], duration: Time, scene: RenderScene) -> [FrameInstruction] {
        let drawn = pieces.filter { $0.content != nil }
        var marks: Set<Time> = [.zero, duration]
        for p in drawn {
            marks.formUnion([p.window.start, p.window.end])
            if let (_, w, _) = p.transitionIn { marks.formUnion([w.start, w.end]) }
            if let (_, w) = p.transitionOut { marks.formUnion([w.start, w.end]) }
        }
        let times = marks.filter { $0 >= .zero && $0 <= duration }.sorted()
        let byTrack = Dictionary(grouping: drawn, by: \.trackIndex)
        let order = byTrack.keys.sorted()
        func layer(_ p: VisualPiece) -> RenderLayer { RenderLayer(content: p.content!, clip: p.clip, source: p.source) }

        return zip(times, times.dropFirst()).map { a, b in
            var items: [FrameItem] = []
            for index in order {
                let active = byTrack[index]!.filter { $0.window.start < b && $0.window.end > a }.sorted { $0.window.start < $1.window.start }
                if active.count >= 2 {
                    let (x, y) = (active[active.count - 2], active[active.count - 1])
                    if case let (t, w, true)? = y.transitionIn, w.contains(a) {
                        items.append(.transition(t, window: w, from: layer(x), to: layer(y)))
                    } else {
                        items += [.layer(layer(x)), .layer(layer(y))]
                    }
                } else if let p = active.first {
                    if case let (t, w, false)? = p.transitionIn, w.contains(a) {
                        items.append(.transition(t, window: w, from: nil, to: layer(p)))
                    } else if let (t, w) = p.transitionOut, w.contains(a) {
                        items.append(.transition(t, window: w, from: layer(p), to: nil))
                    } else {
                        items.append(.layer(layer(p)))
                    }
                }
            }
            return FrameInstruction(timeRange: TimeRange(start: a, end: b).cmTimeRange, scene: scene, items: items)
        }
    }

    /// Transcribed speech on the timeline, words closer than half a second merged.
    static func speech(in project: Project) -> [TimeRange] {
        let gap = Time(value: 1, timescale: 2)
        var merged: [TimeRange] = []
        for word in project.timelineWords() {
            if let last = merged.last, word.range.start - last.end <= gap {
                merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, word.range.end))
            } else {
                merged.append(word.range)
            }
        }
        return merged
    }
}

nonisolated extension ColorSpace {
    /// Primaries, transfer function and matrix to tag rendered frames with.
    var videoColorProperties: (String, String, String) {
        switch self {
        case .rec709: (AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_709_2)
        case .displayP3: (AVVideoColorPrimaries_P3_D65, AVVideoTransferFunction_IEC_sRGB, AVVideoYCbCrMatrix_ITU_R_709_2)
        case .rec2020HLG: (AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrix_ITU_R_2020)
        case .rec2020PQ: (AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunction_SMPTE_ST_2084_PQ, AVVideoYCbCrMatrix_ITU_R_2020)
        }
    }
}
