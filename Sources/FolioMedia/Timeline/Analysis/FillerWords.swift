import Foundation

/// "Um", "uh" and filler "like", from a transcript.
///
/// Apple's transcribers often leave hesitations out of the text, so this finds only the ones
/// that made it into the transcript; it never claims a file is filler-free.
nonisolated enum FillerWords {
    /// Hesitation sounds, always filler.
    static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "eh", "hmm", "mm", "mhm"]

    /// The filler words in `transcript`, in source time, ready for `Project.cut(wordRanges:)`.
    ///
    /// "Like" is only filler when set off from the sentence: by commas ("it was, like, huge")
    /// or by pauses of at least `pause` on both sides.
    static func find(in transcript: Transcript, includeLike: Bool = true, pause: Time = Time(value: 1, timescale: 4)) -> [Word] {
        let words = transcript.words
        return words.indices.compactMap { i -> Word? in
            let word = normalized(words[i].text)
            if hesitations.contains(word) { return words[i] }
            guard includeLike, word == "like" else { return nil }
            let commaBefore = i > 0 && words[i - 1].text.hasSuffix(",")
            let commaAfter = words[i].text.hasSuffix(",")
            let gapBefore = i == 0 || words[i].range.start - words[i - 1].range.end >= pause
            let gapAfter = i == words.count - 1 || words[i + 1].range.start - words[i].range.end >= pause
            return (commaBefore && commaAfter) || (gapBefore && gapAfter) ? words[i] : nil
        }
    }

    /// Lower case, without the punctuation the transcriber attaches.
    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}
