import Foundation

/// Words → caption cues a viewer can read: short enough to fit the lines, long enough to
/// read, and broken where speech breaks (sentence ends, pauses, then commas).
nonisolated enum CueSplitter {
    struct Rules: Equatable, Sendable {
        var maxCharactersPerLine = 42
        var maxLines = 2
        var maxWords = 7
        var maxDuration = Time(value: 3, timescale: 1)
        /// A silence this long always starts a new cue.
        var pause = Time(value: 7, timescale: 10)

        init() {}

        /// The splitting rules a caption track's style asks for.
        init(style: CaptionStyle) {
            maxWords = style.maxWords
            maxDuration = style.maxDuration
        }
    }

    /// Cues for a transcript, in the transcript's (source) time.
    static func cues(for transcript: Transcript, rules: Rules = Rules()) -> [CaptionCue] {
        cues(from: transcript.words, source: transcript.sourceID, rules: rules)
    }

    /// Cues for `words` (sorted). Lines inside a cue are separated by "\n".
    static func cues(from words: [Word], source: SourceID?, rules: Rules = Rules()) -> [CaptionCue] {
        let maxCharacters = rules.maxCharactersPerLine * max(1, rules.maxLines)
        var cues: [CaptionCue] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(
                CaptionCue(
                    text: lines(current.map(\.text), width: rules.maxCharactersPerLine, maxLines: rules.maxLines),
                    range: TimeRange(start: first.range.start, end: last.range.end), source: source, words: current))
            current = []
        }

        for word in words {
            if let first = current.first, let last = current.last {
                let characters = current.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
                let full =
                    current.count >= rules.maxWords || characters > maxCharacters
                    || word.range.end - first.range.start > rules.maxDuration
                let paused = word.range.start - last.range.end >= rules.pause
                // Past half a cue, a comma is a better place to break than wherever it fills up.
                let clause = endsClause(last.text) && characters * 2 > maxCharacters
                if full || paused || endsSentence(last.text) || clause { flush() }
            }
            current.append(word)
        }
        flush()
        return cues
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]")).last else { return false }
        return ".?!…。？！".contains(last)
    }

    static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",;:—、，".contains(last)
    }

    /// Words wrapped greedily into at most `maxLines` lines of `width` characters, then
    /// balanced so two lines are about the same length (easier to read than a long line
    /// over a short one).
    static func lines(_ words: [String], width: Int, maxLines: Int) -> String {
        let text = words.joined(separator: " ")
        guard maxLines > 1, text.count > width, words.count > 1 else { return text }
        if maxLines == 2 {
            // The split point that makes the longer line shortest.
            var best = 1
            var bestLength = Int.max
            for i in 1..<words.count {
                let top = words[..<i].joined(separator: " ").count, bottom = words[i...].joined(separator: " ").count
                if max(top, bottom) < bestLength { (best, bestLength) = (i, max(top, bottom)) }
            }
            return words[..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
        }
        var result: [String] = []
        var line = ""
        for word in words {
            if !line.isEmpty, line.count + 1 + word.count > width, result.count < maxLines - 1 {
                result.append(line)
                line = word
            } else {
                line = line.isEmpty ? word : line + " " + word
            }
        }
        result.append(line)
        return result.joined(separator: "\n")
    }
}
