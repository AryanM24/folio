import Foundation

/// A video project: everything a `.folio-video` file holds. A pure value: edits are
/// `mutating` functions (`Edits.swift`), and undo keeps whole snapshots (`ProjectStore`).
///
/// **Compatibility.** Files carry `version`. Within one version, new stored properties must
/// be optional (or decode with a default), so older files keep opening. Bump
/// `currentVersion` only for a change old builds can't read; they then refuse the file with
/// a plain-language message instead of misreading it.
nonisolated struct Project: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Project.currentVersion
    var settings: ProjectSettings
    /// Every file the project uses, referenced, never copied.
    var sources: [MediaSource] = []
    /// `tracks[0]` is the primary storyline. Visual tracks stack in array order (later on
    /// top); audio tracks mix.
    var tracks: [Track]
    /// Chapters, to-dos and plain markers, sorted by time.
    var markers: [Marker] = []
    /// Word timings per source, in source time, so they survive every edit.
    var transcripts: [Transcript] = []
    var captions: [CaptionTrack] = []

    init(settings: ProjectSettings = ProjectSettings(), tracks: [Track]? = nil) {
        self.settings = settings
        self.tracks = tracks ?? [Track(kind: .video, name: "V1"), Track(kind: .audio, name: "A1")]
    }

    /// A project for one file: canvas and frame rate from the file, the clip on V1.
    /// This is what "Edit in Timeline" opens.
    init(editing source: MediaSource, range: TimeRange? = nil) {
        var settings = ProjectSettings()
        if let rate = source.frameRate { settings.frameRate = rate }
        if let w = source.width, let h = source.height, w > 0, h > 0 { settings.canvas = CanvasSize(width: w, height: h) }
        self.init(settings: settings)
        sources = [source]
        let clip = Clip(source: source, range: range, frameRate: settings.frameRate)
        let lane = source.kind == .audio ? 1 : 0
        tracks[lane].clips = [clip]
    }

    var frameRate: FrameRate { settings.frameRate }
    var frameDuration: Time { settings.frameRate.frameDuration }
    /// End of the last clip on any track.
    var duration: Time { tracks.map(\.end).max() ?? .zero }
    var chapters: [Marker] { markers.filter { $0.kind == .chapter } }

    func source(_ id: SourceID) -> MediaSource? { sources.first { $0.id == id } }
    func track(_ id: TrackID) -> Track? { tracks.first { $0.id == id } }
    func trackIndex(_ id: TrackID) -> Int? { tracks.firstIndex { $0.id == id } }
    func transcript(for source: SourceID) -> Transcript? { transcripts.first { $0.sourceID == source } }

    func location(of clip: ClipID) -> (track: Int, index: Int)? {
        for (t, track) in tracks.enumerated() {
            if let i = track.clips.firstIndex(where: { $0.id == clip }) { return (t, i) }
        }
        return nil
    }

    func clip(_ id: ClipID) -> Clip? {
        location(of: id).map { tracks[$0.track].clips[$0.index] }
    }

    /// Replaces (or adds) the transcript for its source.
    mutating func setTranscript(_ transcript: Transcript) {
        transcripts.removeAll { $0.sourceID == transcript.sourceID }
        transcripts.append(transcript)
    }

    /// Everything that breaks the model's invariants. Empty for a healthy project; tests
    /// assert it after every edit.
    var problems: [String] {
        var found: [String] = []
        var ids = Set<ClipID>()
        let rate = settings.frameRate
        for track in tracks {
            var cursor = Time.zero
            for clip in track.clips {
                let name = "\(track.name) clip \(clip.id)"
                if !ids.insert(clip.id).inserted { found.append("\(name) appears twice") }
                if clip.start < cursor { found.append("\(name) overlaps the clip before it or starts before zero") }
                if clip.duration < rate.frameDuration { found.append("\(name) is shorter than a frame") }
                if !rate.isOnFrame(clip.start) || !rate.isOnFrame(clip.duration) { found.append("\(name) is off the frame grid") }
                if let id = clip.sourceID {
                    if let source = source(id) {
                        if clip.content.usesSourceTime {
                            if clip.sourceStart < .zero { found.append("\(name) starts before its media") }
                            if let length = source.duration, clip.sourceRange.end > length { found.append("\(name) runs past its media") }
                        }
                    } else {
                        found.append("\(name) refers to missing media \(id)")
                    }
                }
                if !track.accepts(clip.content, source: clip.sourceID.flatMap(source)) {
                    found.append("\(name) can't be on a \(track.kind.rawValue) track")
                }
                cursor = clip.end
            }
        }
        if markers != markers.sorted(by: { $0.time < $1.time }) { found.append("Markers are out of order") }
        return found
    }
}

nonisolated struct ProjectSettings: Codable, Equatable, Sendable {
    var canvas = CanvasSize(width: 1920, height: 1080)
    var frameRate = FrameRate.fps30
    var colorSpace = ColorSpace.rec709
    /// Behind everything, where no clip covers the canvas.
    var background = RGBA.black
    var audioSampleRate = 48_000
}

/// The output frame size. Always even, as H.264/HEVC require.
nonisolated struct CanvasSize: Codable, Equatable, Sendable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = max(2, width / 2 * 2)
        self.height = max(2, height / 2 * 2)
    }

    init(_ preset: AspectPreset, shortEdge: Int = 1080) {
        let (w, h) = preset.ratio
        let unit = Double(shortEdge) / Double(min(w, h))
        self.init(width: Int((Double(w) * unit).rounded()), height: Int((Double(h) * unit).rounded()))
    }

    var aspect: AspectPreset? { AspectPreset.allCases.first { $0.matches(width: width, height: height) } }
}

nonisolated enum AspectPreset: String, Codable, Sendable, CaseIterable {
    case widescreen = "16:9"
    case vertical = "9:16"
    case square = "1:1"
    case portrait = "4:5"
    case standard = "4:3"
    case cinema = "21:9"

    var ratio: (Int, Int) {
        switch self {
        case .widescreen: (16, 9)
        case .vertical: (9, 16)
        case .square: (1, 1)
        case .portrait: (4, 5)
        case .standard: (4, 3)
        case .cinema: (21, 9)
        }
    }

    func matches(width: Int, height: Int) -> Bool {
        let (w, h) = ratio
        return abs(Double(width) / Double(height) - Double(w) / Double(h)) < 0.01
    }
}

nonisolated enum ColorSpace: String, Codable, Sendable, CaseIterable {
    case rec709
    case displayP3
    /// HDR. The export needs 10-bit buffers.
    case rec2020HLG
    case rec2020PQ

    var isHDR: Bool { self == .rec2020HLG || self == .rec2020PQ }
}

/// A lane of clips, sorted by start and never overlapping (transitions use handles, not overlap).
nonisolated struct Track: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case video, audio
        /// A video track meant for titles and graphics; drawn like any visual track.
        case title
        var isVisual: Bool { self != .audio }
    }

    var id = TrackID()
    var kind: Kind
    var name: String
    var clips: [Clip] = []
    var isMuted = false
    var isHidden = false
    /// Locked tracks refuse every edit.
    var isLocked = false
    /// Ripple edits on a sync-locked track move every other sync-locked track with them,
    /// so picture and sound stay in step (the Premiere model).
    var isSyncLocked = true
    /// Linear gain for the whole track.
    var volume = 1.0
    /// Lower this track under speech on other tracks (music beds).
    var ducking: Ducking?

    init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// Whether `content` may sit on this track. Pictures go on visual tracks; audio tracks
    /// take media with sound.
    func accepts(_ content: ClipContent, source: MediaSource?) -> Bool {
        switch (kind, content) {
        case (.audio, .media): source.map { $0.kind == .audio || $0.hasAudio } ?? false
        case (.audio, _): false
        case (_, .media): source.map { $0.kind != .audio } ?? false
        default: true
        }
    }
}

nonisolated struct Ducking: Codable, Equatable, Sendable {
    /// How far to lower the track under speech, in dB (negative).
    var amount = -12.0
    /// Ramp length into and out of the dip.
    var fade = Time(value: 1, timescale: 4)
}

nonisolated struct Marker: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case standard
        /// Becomes a chapter in the exported file.
        case chapter
        case todo
    }

    var id = MarkerID()
    /// Timeline time.
    var time: Time
    var name = ""
    var kind = Kind.standard
    var isDone = false
    var note: String?
}
