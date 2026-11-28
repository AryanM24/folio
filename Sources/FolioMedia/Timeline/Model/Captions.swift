import Foundation

// Words and captions are stored in *source* time and mapped onto the timeline when they're
// shown, so cutting, trimming or retiming a clip never leaves a caption behind.

/// What was said in one source, word by word.
nonisolated struct Transcript: Codable, Equatable, Sendable {
    var sourceID: SourceID
    /// BCP-47, e.g. "en-US".
    var locale: String
    /// Sorted by time.
    var words: [Word]
}

nonisolated struct Word: Codable, Equatable, Sendable {
    var text: String
    var range: TimeRange
    var confidence: Double?
}

/// A word where it plays on the timeline. One source word can play several times
/// (a duplicated clip), and each occurrence is its own `TimelineWord`.
nonisolated struct TimelineWord: Equatable, Sendable {
    var text: String
    var range: TimeRange
    var source: SourceID
    var sourceRange: TimeRange
}

/// A caption lane ([CC] in the timeline), exported as SRT/VTT, a soft subtitle track or
/// burned in.
nonisolated struct CaptionTrack: Codable, Equatable, Sendable, Identifiable {
    var id = CaptionID()
    var name = "Captions"
    /// BCP-47, written to the subtitle track.
    var language = "en-US"
    var style = CaptionStyle()
    var cues: [CaptionCue] = []
    var isEnabled = true
    /// Draw into the picture on export (otherwise only files and soft subtitles).
    var burnIn = true
}

nonisolated struct CaptionCue: Codable, Equatable, Sendable, Identifiable {
    var id = CaptionID()
    var text: String
    /// Source time when `source` is set, timeline time when it's `nil` (typed captions).
    var range: TimeRange
    var source: SourceID?
    /// Word timings in the same time base as `range`, for word highlighting and for
    /// dropping words that were cut.
    var words: [Word] = []
}

nonisolated struct CaptionStyle: Codable, Equatable, Sendable {
    enum Placement: String, Codable, Sendable { case bottom, top }

    var text = TextStyle(size: 0.05, box: TextBox())
    var placement = Placement.bottom
    /// Distance from the edge, as a fraction of the canvas height.
    var margin = 0.08
    /// Splitting rules for automatic cues.
    var maxWords = 7
    var maxDuration = Time(value: 3, timescale: 1)
    /// Colour of the word being spoken, or `nil` for no highlight.
    var highlight: RGBA?
}

/// A cue as it plays: timeline time, cut words removed.
nonisolated struct ResolvedCue: Equatable, Sendable {
    var cueID: CaptionID
    var text: String
    var range: TimeRange
    var words: [Word]
}

nonisolated extension Clip {
    /// Where `word` plays in this clip, if most of it survived the edits: the sliver a
    /// padded cut leaves behind doesn't count as the word.
    func timelineRange(of word: Word) -> TimeRange? {
        guard let hit = word.range.intersection(sourceRange), hit.duration * 2 > word.range.duration else { return nil }
        return timelineRange(forSource: word.range)
    }
}

nonisolated extension Project {
    /// Clips that play `source` in time, one per distinct timeline range (a video clip and
    /// its detached audio count once).
    private func playing(_ source: SourceID) -> [Clip] {
        var seen = Set<TimeRange>()
        return tracks.flatMap(\.clips)
            .filter { $0.isEnabled && $0.content == .media(source: source) && seen.insert($0.range).inserted }
            .sorted { $0.start < $1.start }
    }

    /// Where a stretch of source plays on the timeline, earliest first.
    func timelineRanges(forSource source: SourceID, range: TimeRange) -> [TimeRange] {
        playing(source).compactMap { $0.timelineRange(forSource: range) }
    }

    /// Every transcribed word on the timeline, in playback order: the transcript view.
    func timelineWords() -> [TimelineWord] {
        transcripts.flatMap { transcript in
            playing(transcript.sourceID).flatMap { clip in
                transcript.words.compactMap { word in
                    clip.timelineRange(of: word).map {
                        TimelineWord(text: word.text, range: $0, source: transcript.sourceID, sourceRange: word.range)
                    }
                }
            }
        }
        .sorted { $0.range.start < $1.range.start }
    }

    /// The cues of `track` in timeline time, in order. A source cue shows wherever its
    /// media plays; pieces that end up next to each other (after a cut inside the cue)
    /// merge into one cue without the words that were cut.
    func resolvedCues(_ track: CaptionTrack) -> [ResolvedCue] {
        var result: [ResolvedCue] = []
        for cue in track.cues {
            guard let source = cue.source else {
                result.append(ResolvedCue(cueID: cue.id, text: cue.text, range: cue.range, words: cue.words))
                continue
            }
            var pieces: [(clip: Clip, range: TimeRange)] = playing(source).compactMap { clip in
                clip.timelineRange(forSource: cue.range).map { (clip, $0) }
            }
            while !pieces.isEmpty {
                var run = [pieces.removeFirst()]
                while let next = pieces.first, next.range.start == run.last!.range.end { run.append(pieces.removeFirst()) }
                let span = TimeRange(start: run[0].range.start, end: run.last!.range.end)
                let words = cue.words.compactMap { word -> Word? in
                    for piece in run {
                        if let r = piece.clip.timelineRange(of: word)?.intersection(piece.range) {
                            return Word(text: word.text, range: r, confidence: word.confidence)
                        }
                    }
                    return nil
                }
                let text = words.count == cue.words.count ? cue.text : words.map(\.text).joined(separator: " ")
                if !cue.words.isEmpty && words.isEmpty { continue }
                result.append(ResolvedCue(cueID: cue.id, text: text, range: span, words: words))
            }
        }
        return result.sorted { $0.range.start < $1.range.start }
    }
}
