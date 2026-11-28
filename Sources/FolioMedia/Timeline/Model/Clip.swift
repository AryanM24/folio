import Foundation

/// A type-safe UUID: a `ClipID` can't be passed where a `TrackID` is expected.
nonisolated struct Identifier<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    let raw: UUID

    init() { raw = UUID() }
    init(_ raw: UUID) { self.raw = raw }

    init(from decoder: any Decoder) throws { raw = try decoder.singleValueContainer().decode(UUID.self) }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    var description: String { raw.uuidString }
}

nonisolated enum ClipTag {}
nonisolated enum TrackTag {}
nonisolated enum SourceTag {}
nonisolated enum MarkerTag {}
nonisolated enum GroupTag {}
nonisolated enum EffectTag {}
nonisolated enum CaptionTag {}

typealias ClipID = Identifier<ClipTag>
typealias TrackID = Identifier<TrackTag>
typealias SourceID = Identifier<SourceTag>
typealias MarkerID = Identifier<MarkerTag>
/// Clips sharing a group move, delete and copy together (detached audio, user groups).
typealias GroupID = Identifier<GroupTag>
typealias EffectID = Identifier<EffectTag>
typealias CaptionID = Identifier<CaptionTag>

/// What a clip shows or plays.
nonisolated enum ClipContent: Codable, Equatable, Sendable {
    /// A movie or sound file. On a video track it shows the picture (and plays its sound
    /// unless `audio.isEnabled` is off); on an audio track it plays the sound only.
    case media(source: SourceID)
    /// A still picture, held for the clip's duration. Ken Burns is crop keyframes.
    case image(source: SourceID)
    /// One frame of a movie, held. `at` is source time.
    case freeze(source: SourceID, at: Time)
    case color(RGBA)
    case title(Title)

    var sourceID: SourceID? {
        switch self {
        case .media(let s), .image(let s), .freeze(let s, _): s
        case .color, .title: nil
        }
    }

    /// Only media clips walk through source time; everything else is a still.
    var usesSourceTime: Bool {
        if case .media = self { true } else { false }
    }
}

/// One clip on a track.
///
/// The timeline side (`start`, `duration`) is the source of truth and is always on a frame
/// boundary. The source side is derived: `sourceStart` plus however much media `retime`
/// consumes over `duration`. So timeline edits stay frame-exact at any speed.
nonisolated struct Clip: Codable, Equatable, Sendable, Identifiable {
    var id = ClipID()
    /// Display name; `nil` shows the source's name.
    var name: String?
    var content: ClipContent
    /// Timeline time of the first frame.
    var start: Time
    /// Timeline length. At least one frame.
    var duration: Time
    /// Media clips: the earliest source time used (the first frame shown, unless reversed).
    var sourceStart = Time.zero
    var retime = Retime()
    /// A disabled clip stays on the timeline but isn't seen or heard.
    var isEnabled = true
    var groupID: GroupID?
    var transform = Transform()
    var effects: [Effect] = []
    var audio = AudioSettings()
    var transitionIn: ClipTransition?
    var transitionOut: ClipTransition?

    init(content: ClipContent, start: Time = .zero, duration: Time, sourceStart: Time = .zero) {
        self.content = content
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
    }

    /// A clip of `source`, `range` in source time (default: all of it; 5 s for an image),
    /// cut down to whole frames at `frameRate`.
    init(source: MediaSource, range: TimeRange? = nil, frameRate: FrameRate) {
        let fiveSeconds = Time(value: 5, timescale: 1)
        let range = range ?? TimeRange(start: .zero, duration: source.duration ?? fiveSeconds)
        let duration = max(frameRate.frameDuration, frameRate.floor(range.duration))
        switch source.kind {
        case .image: self.init(content: .image(source: source.id), duration: duration)
        case .video, .audio: self.init(content: .media(source: source.id), duration: duration, sourceStart: range.start)
        }
    }

    var end: Time { start + duration }
    var range: TimeRange { TimeRange(start: start, duration: duration) }
    var sourceID: SourceID? { content.sourceID }

    /// Source time this clip plays (media clips).
    var sourceDuration: Time { retime.sourceOffset(at: duration) }
    var sourceRange: TimeRange { TimeRange(start: sourceStart, duration: sourceDuration) }

    /// The source time shown `offset` into the clip, or `nil` for content without one.
    func sourceTime(atOffset offset: Time) -> Time? {
        switch content {
        case .media:
            let consumed = retime.sourceOffset(at: offset)
            return retime.reversed ? sourceStart + sourceDuration - consumed : sourceStart + consumed
        case .freeze(_, let at): return at
        case .image, .color, .title: return nil
        }
    }

    /// Where `source` (a source-time range) plays on the timeline, or `nil` if this clip
    /// doesn't use any of it.
    func timelineRange(forSource source: TimeRange) -> TimeRange? {
        guard content.usesSourceTime, let hit = source.intersection(sourceRange) else { return nil }
        let total = sourceDuration
        let (lo, hi) =
            retime.reversed
            ? (sourceStart + total - hit.end, sourceStart + total - hit.start)
            : (hit.start - sourceStart, hit.end - sourceStart)
        guard let a = retime.timelineOffset(forSource: lo), let b = retime.timelineOffset(forSource: hi) else { return nil }
        let t0 = max(.zero, a), t1 = min(duration, b)
        return t1 > t0 ? TimeRange(start: start + t0, end: start + t1) : nil
    }

    /// The clip as constant-speed pieces: what `scaleTimeRange` needs, one call per piece.
    /// Empty for content without source time.
    func timeMap() -> [TimeMapSegment] {
        guard content.usesSourceTime else { return [] }
        let total = sourceDuration
        let bounds = [Time.zero] + retime.segments.map(\.start).filter { $0 > .zero && $0 < duration } + [duration]
        return zip(bounds, bounds.dropFirst()).map { lo, hi in
            let o0 = retime.sourceOffset(at: lo), o1 = retime.sourceOffset(at: hi)
            let source =
                retime.reversed
                ? TimeRange(start: sourceStart + total - o1, end: sourceStart + total - o0)
                : TimeRange(start: sourceStart + o0, end: sourceStart + o1)
            return TimeMapSegment(
                timeline: TimeRange(start: start + lo, end: start + hi), source: source,
                speed: retime.speed(at: lo), reversed: retime.reversed)
        }
    }

    /// The same clip cut down (or extended) to `window`, in timeline time. Source mapping,
    /// speed changes and keyframes follow, so every frame inside the window looks the same.
    ///
    /// Transitions and fades belong to an edge: an edge that moved loses them, unless
    /// `keepEdges` (a trim moves the edge but it's still the clip's edge).
    func reframed(to window: TimeRange, keepEdges: Bool = false) -> Clip {
        var clip = self
        let offsets = TimeRange(start: window.start - start, end: window.end - start)
        clip.start = window.start
        clip.duration = window.duration
        if content.usesSourceTime {
            clip.sourceStart =
                retime.reversed
                ? sourceStart + sourceDuration - retime.sourceOffset(at: offsets.end)
                : sourceStart + retime.sourceOffset(at: offsets.start)
        }
        clip.retime = retime.rebased(to: offsets)
        clip.rebaseKeyframes(to: offsets)
        if !keepEdges {
            if offsets.start != .zero {
                clip.transitionIn = nil
                clip.audio.fadeIn = .zero
            }
            if offsets.end != duration {
                clip.transitionOut = nil
                clip.audio.fadeOut = .zero
            }
        }
        clip.audio.fadeIn = min(clip.audio.fadeIn, clip.duration)
        clip.audio.fadeOut = min(clip.audio.fadeOut, clip.duration)
        return clip
    }

    private mutating func rebaseKeyframes(to window: TimeRange) {
        transform.position = transform.position.rebased(to: window)
        transform.scale = transform.scale.rebased(to: window)
        transform.rotation = transform.rotation.rebased(to: window)
        transform.opacity = transform.opacity.rebased(to: window)
        transform.crop = transform.crop.rebased(to: window)
        audio.volume = audio.volume.rebased(to: window)
        audio.pan = audio.pan.rebased(to: window)
        for i in effects.indices {
            if case .redact(var regions) = effects[i].kind {
                for r in regions.indices { regions[r].rect = regions[r].rect.rebased(to: window) }
                effects[i].kind = .redact(regions)
            }
        }
    }
}

/// One constant-speed piece of a media clip.
nonisolated struct TimeMapSegment: Equatable, Sendable {
    var timeline: TimeRange
    var source: TimeRange
    var speed: Rational
    /// The piece plays `source` backwards.
    var reversed: Bool
}

// MARK: - Speed

/// A change of speed at `start` (an offset into the clip, timeline time), lasting until
/// the next segment. Speed 0 holds the frame.
nonisolated struct SpeedSegment: Codable, Equatable, Sendable {
    var start: Time
    var speed: Rational
}

/// How a clip walks through its source: constant speed, ramps, reverse.
nonisolated struct Retime: Codable, Equatable, Sendable {
    /// Sorted by start; the first starts at zero. Empty means 1×.
    var segments: [SpeedSegment] = []
    /// Plays the source range backwards (rendered from a cached reversed copy).
    var reversed = false
    /// Keep the voice's pitch when the speed changes.
    var preservesPitch = true

    init() {}

    init(speed: Rational) {
        if speed != .one { segments = [SpeedSegment(start: .zero, speed: speed)] }
    }

    var isIdentity: Bool { segments.isEmpty && !reversed }
    /// The one speed of a clip without ramps.
    var constantSpeed: Rational? { segments.count <= 1 ? (segments.first?.speed ?? .one) : nil }

    private var pieces: [SpeedSegment] { segments.isEmpty ? [SpeedSegment(start: .zero, speed: .one)] : segments }

    /// Speed at `offset`. Before zero it's the first speed, past the last change the last.
    func speed(at offset: Time) -> Rational {
        pieces.last { $0.start <= offset }?.speed ?? pieces[0].speed
    }

    /// Source time consumed from the clip's start to `offset`. Negative offsets (an edge
    /// pulled out past the start) use the first speed.
    func sourceOffset(at offset: Time) -> Time {
        let pieces = pieces
        guard offset > .zero else { return offset * pieces[0].speed }
        var total = Time.zero
        for (i, piece) in pieces.enumerated() {
            let lo = i == 0 ? Time.zero : piece.start
            guard offset > lo else { break }
            let hi = i + 1 < pieces.count ? min(offset, pieces[i + 1].start) : offset
            total += (hi - lo) * piece.speed
        }
        return total
    }

    /// The first timeline offset at which `source` of source time has been consumed, or
    /// `nil` if it never is (the clip ends in a hold).
    func timelineOffset(forSource source: Time) -> Time? {
        let pieces = pieces
        if source == .zero { return .zero }
        if source < .zero { return pieces[0].speed > .zero ? source / pieces[0].speed : nil }
        var consumed = Time.zero
        for (i, piece) in pieces.enumerated() where piece.speed > .zero {
            let lo = i == 0 ? Time.zero : piece.start
            guard i + 1 < pieces.count else { return lo + (source - consumed) / piece.speed }
            let reach = consumed + (pieces[i + 1].start - lo) * piece.speed
            if source <= reach { return lo + (source - consumed) / piece.speed }
            consumed = reach
        }
        return nil
    }

    /// The speed changes seen by a clip cut to `window` (old offsets), rebased to zero.
    func rebased(to window: TimeRange) -> Retime {
        guard !segments.isEmpty else { return self }
        var result = self
        var next = [SpeedSegment(start: .zero, speed: speed(at: window.start))]
        for piece in segments where piece.start > window.start && piece.start < window.end {
            if next.last?.speed != piece.speed { next.append(SpeedSegment(start: piece.start - window.start, speed: piece.speed)) }
        }
        result.segments = next.count == 1 && next[0].speed == .one ? [] : next
        return result
    }
}

// MARK: - Geometry

/// Where and how a visual clip sits on the canvas. Applied after the source's own
/// orientation (`preferredTransform`), in this order: crop, fit, scale, rotate, flip, move.
nonisolated struct Transform: Codable, Equatable, Sendable {
    enum Fit: String, Codable, Sendable, CaseIterable {
        /// Whole picture visible, bars where the aspect differs (the default).
        case fit
        /// Fills the canvas, cropping the overflow.
        case fill
        case stretch
        /// Pixel for pixel.
        case none
    }

    var fit = Fit.fit
    /// Offset of the layer's centre from the canvas centre, in canvas fractions.
    var position = Keyframed(Vec2.zero)
    /// 1 is the fitted size.
    var scale = Keyframed(1.0)
    /// Degrees clockwise.
    var rotation = Keyframed(0.0)
    var opacity = Keyframed(1.0)
    /// Removed from the source frame before fitting.
    var crop = Keyframed(Insets.zero)
    var flipHorizontal = false
    var flipVertical = false
    /// Shapes the layer (a round camera bubble, rounded picture-in-picture).
    var mask: LayerMask?
    /// What fills the canvas around a fitted picture (blurred copy for vertical video).
    var backdrop: Backdrop?

    var isIdentity: Bool { self == Transform() }
}

nonisolated enum LayerMask: Codable, Equatable, Sendable {
    /// Corner radius as a fraction of the shorter side.
    case roundedRect(cornerRadius: Double)
    case ellipse
}

nonisolated enum Backdrop: Codable, Equatable, Sendable {
    /// A scaled-up, blurred copy of the same frame. Radius is a fraction of the frame height.
    case blurred(radius: Double)
    case color(RGBA)
}

// MARK: - Sound

nonisolated struct AudioSettings: Codable, Equatable, Sendable {
    /// Off after Detach Audio: the sound plays from the linked audio clip instead.
    var isEnabled = true
    /// Linear gain; 1 is unchanged (0 dB).
    var volume = Keyframed(1.0)
    /// −1 left … 1 right.
    var pan = Keyframed(0.0)
    var fadeIn = Time.zero
    var fadeOut = Time.zero
    /// Run the sound through Voice Isolation (rendered once, cached).
    var isolateVoice = false

    /// Linear gain for decibels.
    static func gain(decibels: Double) -> Double { pow(10, decibels / 20) }
}
