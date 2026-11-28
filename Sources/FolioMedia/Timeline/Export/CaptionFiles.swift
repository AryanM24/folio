import FolioKit
import Foundation

/// One subtitle as files and the subtitle track hold it: timeline time and plain text.
nonisolated struct SubtitleCue: Equatable, Sendable {
    var range: TimeRange
    var text: String

    /// A typed caption for the model (timeline time, no source).
    var captionCue: CaptionCue { CaptionCue(text: text, range: range) }
}

nonisolated extension Project {
    /// What the export writes for `track`: its cues in timeline time, cut words removed.
    func subtitleCues(_ track: CaptionTrack) -> [SubtitleCue] {
        resolvedCues(track).map { SubtitleCue(range: $0.range, text: $0.text) }
    }
}

/// SRT and WebVTT, written and read, plus a basic ASS export. Pure string code.
///
/// The two differ in small ways that players are strict about: SRT numbers its cues and
/// writes `00:00:01,500`; VTT starts with `WEBVTT`, writes `00:00:01.500` and escapes `&`/`<`.
nonisolated enum CaptionFiles {
    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { i, cue in
            "\(i + 1)\n\(stamp(cue.range.start, ",")) --> \(stamp(cue.range.end, ","))\n\(cue.text)\n"
        }
        .joined(separator: "\n")
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        let body = cues.map { cue in
            let text = cue.text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
            return "\(stamp(cue.range.start, ".")) --> \(stamp(cue.range.end, "."))\n\(text)\n"
        }
        return (["WEBVTT\n"] + body).joined(separator: "\n")
    }

    /// Advanced SubStation Alpha with one style taken from the caption style. Times are
    /// centiseconds and line breaks are `\N`, as the format requires.
    static func ass(_ cues: [SubtitleCue], canvas: CanvasSize, style: CaptionStyle = CaptionStyle()) -> String {
        let h = Double(canvas.height)
        let size = Int((style.text.size * h).rounded())
        let alignment = style.placement == .top ? 8 : 2
        let margin = Int((style.margin * h).rounded())
        let font = style.text.fontName ?? "Helvetica"
        let bold = style.text.weight == .regular || style.text.weight == .medium ? 0 : -1
        let events = cues.map { cue in
            let text = cue.text.replacing("\r\n", with: "\n").replacing("\n", with: "\\N")
            return "Dialogue: 0,\(assStamp(cue.range.start)),\(assStamp(cue.range.end)),Default,,0,0,0,,\(text)"
        }
        return """
            [Script Info]
            ScriptType: v4.00+
            PlayResX: \(canvas.width)
            PlayResY: \(canvas.height)
            WrapStyle: 0

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, \
            StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,\(font),\(size),&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,\(bold),0,0,0,100,100,0,0,1,2,0,\(alignment),\
            \(margin),\(margin),\(margin),1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

            """ + events.joined(separator: "\n") + "\n"
    }

    /// Reads SRT or WebVTT (told apart by the `WEBVTT` header). Cue numbers, VTT cue
    /// identifiers, cue settings, NOTE/STYLE/REGION blocks and CRLF line ends are all
    /// accepted. Throws on a timing line that isn't one.
    static func parse(_ text: String) throws -> [SubtitleCue] {
        var lines = text.replacing("\r\n", with: "\n").replacing("\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = first.dropFirst() }
        let isVTT = lines.first?.hasPrefix("WEBVTT") ?? false
        var cues: [SubtitleCue] = []
        var block: [Substring] = []
        var blockStart = 0
        func flush() throws {
            defer { block = [] }
            guard let arrow = block.firstIndex(where: { $0.contains("-->") }) else { return }
            if isVTT, let head = block.first, ["NOTE", "STYLE", "REGION"].contains(where: { head.hasPrefix($0) }) { return }
            let parts = block[arrow].components(separatedBy: "-->")
            let endField = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            guard let start = time(parts[0].trimmingCharacters(in: .whitespaces)), let end = time(endField), end >= start else {
                throw FolioError("Line \(blockStart + arrow + 1) isn't a valid subtitle timing: “\(block[arrow])”.")
            }
            var body = block[(arrow + 1)...].joined(separator: "\n")
            if isVTT { body = body.replacing("&lt;", with: "<").replacing("&gt;", with: ">").replacing("&amp;", with: "&") }
            cues.append(SubtitleCue(range: TimeRange(start: start, end: end), text: body))
        }
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                try flush()
                blockStart = i + 1
            } else {
                block.append(line)
            }
        }
        try flush()
        return cues
    }

    // MARK: Timestamps

    private static func milliseconds(_ time: Time) -> Int { max(0, Int((time.seconds * 1000).rounded())) }

    /// `hh:mm:ss<sep>mmm`.
    private static func stamp(_ time: Time, _ separator: String) -> String {
        let ms = milliseconds(time)
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }

    /// `h:mm:ss.cc`.
    private static func assStamp(_ time: Time) -> String {
        let cs = (milliseconds(time) + 5) / 10
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
    }

    /// `hh:mm:ss,mmm`, `hh:mm:ss.mmm` or VTT's short `mm:ss.mmm`, as exact milliseconds.
    static func time(_ field: String) -> Time? {
        let clock = field.split(separator: ":")
        guard (2...3).contains(clock.count), let last = clock.last else { return nil }
        let secondParts = last.split(whereSeparator: { $0 == "," || $0 == "." })
        guard (1...2).contains(secondParts.count), let s = Int(secondParts[0]), s < 60 else { return nil }
        let fraction = secondParts.count == 2 ? String(secondParts[1]) : "0"
        guard let digits = Int(fraction), fraction.count <= 3 else { return nil }
        let ms = digits * [1000, 100, 10, 1][fraction.count]
        let numbers = clock.dropLast().map { Int($0) }
        guard !numbers.contains(nil) else { return nil }
        let units = numbers.compactMap(\.self)
        let minutes = units.count == 2 ? units[0] * 60 + units[1] : units[0]
        return Time(value: Int64((minutes * 60 + s) * 1000 + ms), timescale: 1000)
    }
}
