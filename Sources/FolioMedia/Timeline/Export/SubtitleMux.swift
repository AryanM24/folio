import AVFoundation
import FolioConvert
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

/// Adds soft subtitles and chapters to a finished movie without re-encoding it: model time
/// in, `CompositionEncoder.addText` (FolioConvert) does the remux.
nonisolated enum SubtitleMux {
    static func mux(
        _ movie: URL, subtitles: [SubtitleCue], language: String = "en-US", chapters: [Chapter], to output: URL, fileType: AVFileType
    ) async throws {
        let duration = try await AVURLAsset(url: movie).load(.duration)
        guard let end = Time(duration) else { throw FolioError("Couldn't read the movie's length.") }
        let cues = subtitles.compactMap { cue -> (String, TimeRange)? in
            let r = TimeRange(start: max(.zero, cue.range.start), end: min(end, cue.range.end))
            return r.isEmpty ? nil : (cue.text, r)
        }
        let sorted = chapters.filter { $0.start < end }.sorted { $0.start < $1.start }
        // The first chapter starts the movie: players have nothing to show before it.
        let marks = sorted.indices.map { i -> (String, TimeRange) in
            let start = i == 0 ? Time.zero : sorted[i].start
            let stop = i + 1 < sorted.count ? sorted[i + 1].start : end
            return (sorted[i].title, TimeRange(start: start, end: stop))
        }
        let timed = { (spans: [(String, TimeRange)]) in spans.map { TimedText(text: $0.0, range: $0.1.cmTimeRange) } }
        do {
            try await CompositionEncoder.addText(
                to: movie, subtitles: timed(filled(cues.sorted { $0.1.start < $1.1.start }, until: end)),
                chapters: timed(marks.filter { !$0.1.isEmpty }), language: language, output: output, fileType: fileType)
        } catch let error as ConvertError {
            throw FolioError("Adding subtitles failed: \(error.message)")
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
}
