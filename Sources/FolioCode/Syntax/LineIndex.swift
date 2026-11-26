import Foundation

/// UTF-16 offset of the start of every line, kept up to date as the text changes.
///
/// The gutter, Ln/Col, go-to-line, and the highlighter's per-line state cache all need
/// "which line is offset N on" in O(log n). Edits patch only the affected entries and
/// shift the rest, so a keystroke in a 10 MB file costs a memmove, not a rescan.
nonisolated struct LineIndex: Sendable {
    private(set) var starts: [Int] = [0]

    var count: Int { starts.count }

    init() {}

    init(_ text: NSString) {
        starts = [0] + Self.lineStarts(in: text, range: NSRange(location: 0, length: text.length))
    }

    /// Zero-based line containing `offset` (an offset at a line start belongs to that line).
    func line(containing offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func start(ofLine line: Int) -> Int { starts[max(0, min(line, starts.count - 1))] }

    /// The line's characters without its newline.
    func contentRange(ofLine line: Int, length: Int) -> NSRange {
        let start = start(ofLine: line)
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Applies an edit reported by `NSTextStorage`: `editedRange` is in the new text and
    /// `delta` is the change in length. Returns the first affected line and how many line
    /// starts were removed and inserted after it, so parallel per-line arrays can follow.
    @discardableResult
    mutating func apply(editedRange: NSRange, delta: Int, in text: NSString) -> (line: Int, removed: Int, inserted: Int) {
        let location = editedRange.location
        let oldEnd = location + editedRange.length - delta
        let first = line(containing: location)
        var end = first + 1
        while end < starts.count, starts[end] <= oldEnd { end += 1 }
        if delta != 0 {
            for k in end..<starts.count { starts[k] += delta }
        }
        let added = Self.lineStarts(in: text, range: editedRange)
        starts.replaceSubrange(first + 1..<end, with: added)
        return (first, end - first - 1, added.count)
    }

    /// Offsets just past every `\n` in `range`.
    private static func lineStarts(in text: NSString, range: NSRange) -> [Int] {
        var result: [Int] = []
        let chunk = 16_384
        var buffer = [UInt16](repeating: 0, count: chunk)
        var position = range.location
        let end = range.location + range.length
        while position < end {
            let length = min(chunk, end - position)
            buffer.withUnsafeMutableBufferPointer { b in
                guard let base = b.baseAddress else { return }
                text.getCharacters(base, range: NSRange(location: position, length: length))
                for k in 0..<length where b[k] == 10 { result.append(position + k + 1) }
            }
            position += length
        }
        return result
    }
}
