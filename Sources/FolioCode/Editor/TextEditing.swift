import Foundation

/// One replacement plus where the selection goes afterwards.
nonisolated struct TextEdit: Equatable, Sendable {
    var range: NSRange
    var replacement: String
    var selection: NSRange

    /// No text change, only a caret move (typing over an auto-inserted `)`).
    var isCaretMoveOnly: Bool { range.length == 0 && replacement.isEmpty }
}

/// The editing commands (indent, comment, move line, auto-pairing…) as pure functions from
/// text + selection to a ``TextEdit``.
///
/// Keeping them free of AppKit means they're unit-tested, and the text view applies every
/// result the same way, through `shouldChangeText`, so each one is a single undo step.
nonisolated enum TextEditing {
    private static let newline: UInt16 = 10

    // MARK: Lines

    /// Whole lines touched by the selection, including the last line's newline. A selection
    /// that ends right after a newline doesn't pull in the next line.
    static func lineBlock(_ s: NSString, _ selection: NSRange) -> NSRange {
        var r = selection
        if r.length > 0, r.upperBound <= s.length, s.character(at: r.upperBound - 1) == newline { r.length -= 1 }
        return s.lineRange(for: r)
    }

    /// The lines in `block`, without newlines, and whether the block ended with one.
    private static func lines(_ s: NSString, _ block: NSRange) -> (lines: [String], trailingNewline: Bool) {
        var text = s.substring(with: block)
        let trailing = text.hasSuffix("\n")
        if trailing { text.removeLast() }
        return (text.components(separatedBy: "\n"), trailing)
    }

    private static func join(_ lines: [String], _ trailing: Bool) -> String {
        lines.joined(separator: "\n") + (trailing ? "\n" : "")
    }

    private static func leadingWhitespace(_ line: String) -> Substring { line.prefix { $0 == " " || $0 == "\t" } }

    private static func length(_ s: some StringProtocol) -> Int { s.utf16.count }

    /// Selection after a whole-line command: the caret moves with its line's edit; a range
    /// selection covers the rewritten lines.
    private static func selection(after original: NSRange, block: NSRange, oldFirstLine: String, newFirstLine: String, replacement: String, trailing: Bool) -> NSRange {
        if original.length == 0, !replacement.dropLast(trailing ? 1 : 0).contains("\n") {
            let delta = length(newFirstLine) - length(oldFirstLine)
            let column = original.location - block.location
            // Text added or removed at the indentation shifts the caret, but never before the line start.
            let moved = max(0, column + (column >= length(leadingWhitespace(oldFirstLine)) || delta > 0 ? delta : 0))
            return NSRange(location: block.location + min(moved, length(newFirstLine)), length: 0)
        }
        return NSRange(location: block.location, length: length(replacement) - (trailing ? 1 : 0))
    }

    // MARK: Indentation

    static func indent(_ s: NSString, selection: NSRange, unit: String) -> TextEdit {
        let block = lineBlock(s, selection)
        let (old, trailing) = lines(s, block)
        let new = old.map { $0.isEmpty ? $0 : unit + $0 }
        let replacement = join(new, trailing)
        return TextEdit(range: block, replacement: replacement,
                        selection: self.selection(after: selection, block: block, oldFirstLine: old[0], newFirstLine: new[0], replacement: replacement, trailing: trailing))
    }

    static func outdent(_ s: NSString, selection: NSRange, width: Int) -> TextEdit {
        let block = lineBlock(s, selection)
        let (old, trailing) = lines(s, block)
        let new = old.map { line -> String in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(spaces, width)))
        }
        let replacement = join(new, trailing)
        return TextEdit(range: block, replacement: replacement,
                        selection: self.selection(after: selection, block: block, oldFirstLine: old[0], newFirstLine: new[0], replacement: replacement, trailing: trailing))
    }

    /// Tab: indents a multi-line selection, otherwise inserts a tab or spaces up to the next stop.
    static func tab(_ s: NSString, selection: NSRange, style: IndentStyle) -> TextEdit {
        if selection.length > 0, s.substring(with: selection).contains("\n") {
            return indent(s, selection: selection, unit: style.unit)
        }
        let insert: String
        if style.usesTabs {
            insert = "\t"
        } else {
            let lineStart = s.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let column = selection.location - lineStart
            insert = String(repeating: " ", count: style.width - column % max(1, style.width))
        }
        return TextEdit(range: selection, replacement: insert, selection: NSRange(location: selection.location + length(insert), length: 0))
    }

    // MARK: Comments

    /// ⌘/: comments out the lines, or uncomments them when every non-blank line already is.
    static func toggleComment(_ s: NSString, selection: NSRange, lineComment: String?, blockComment: (open: String, close: String)?) -> TextEdit? {
        let block = lineBlock(s, selection)
        let (old, trailing) = lines(s, block)
        let filled = old.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !filled.isEmpty else { return nil }
        var new = old

        if let token = lineComment {
            let commented = filled.allSatisfy { $0.drop { $0 == " " || $0 == "\t" }.hasPrefix(token) }
            if commented {
                new = old.map { line in
                    let indent = leadingWhitespace(line)
                    var rest = line.dropFirst(indent.count)
                    guard rest.hasPrefix(token) else { return line }
                    rest = rest.dropFirst(token.count)
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    return String(indent) + rest
                }
            } else {
                let column = filled.map { leadingWhitespace($0).count }.min() ?? 0
                new = old.map { line in
                    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                    return String(line.prefix(column)) + token + " " + line.dropFirst(column)
                }
            }
        } else if let (open, close) = blockComment {
            let body = join(old, false)
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(open), trimmed.hasSuffix(close), trimmed.count >= open.count + close.count {
                var text = body
                if let r = text.range(of: open) {
                    var end = r.upperBound
                    if end < text.endIndex, text[end] == " " { end = text.index(after: end) }
                    text.removeSubrange(r.lowerBound..<end)
                }
                if let r = text.range(of: close, options: .backwards) {
                    var start = r.lowerBound
                    if start > text.startIndex, text[text.index(before: start)] == " " { start = text.index(before: start) }
                    text.removeSubrange(start..<r.upperBound)
                }
                new = text.components(separatedBy: "\n")
            } else {
                let indent = leadingWhitespace(body)
                new = (String(indent) + open + " " + body.dropFirst(indent.count) + " " + close).components(separatedBy: "\n")
            }
        } else {
            return nil
        }
        let replacement = join(new, trailing)
        return TextEdit(range: block, replacement: replacement,
                        selection: self.selection(after: selection, block: block, oldFirstLine: old[0], newFirstLine: new[0], replacement: replacement, trailing: trailing))
    }

    // MARK: Moving and duplicating lines

    /// ⌥⌘↑ / ⌥⌘↓: swaps the selected lines with the line above or below.
    static func moveLines(_ s: NSString, selection: NSRange, up: Bool) -> TextEdit? {
        let block = lineBlock(s, selection)
        let (blockLines, blockTrailing) = lines(s, block)
        let body = blockLines.joined(separator: "\n")
        if up {
            guard block.location > 0 else { return nil }
            let above = s.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let prev = s.substring(with: NSRange(location: above.location, length: above.length - 1))
            let replacement = body + "\n" + prev + (blockTrailing ? "\n" : "")
            let shift = length(prev) + 1
            return TextEdit(range: NSRange(location: above.location, length: block.upperBound - above.location),
                            replacement: replacement, selection: NSRange(location: selection.location - shift, length: selection.length))
        }
        // The last line (or the line before an empty last line) has nothing below to swap with.
        guard blockTrailing, block.upperBound < s.length else { return nil }
        let below = s.lineRange(for: NSRange(location: block.upperBound, length: 0))
        let (nextLines, nextTrailing) = lines(s, below)
        let next = nextLines.joined(separator: "\n")
        let replacement = next + "\n" + body + (nextTrailing ? "\n" : "")
        return TextEdit(range: NSRange(location: block.location, length: below.upperBound - block.location),
                        replacement: replacement, selection: NSRange(location: selection.location + length(next) + 1, length: selection.length))
    }

    /// ⇧⌘D: copies the selected lines below themselves and selects the copy.
    static func duplicateLines(_ s: NSString, selection: NSRange) -> TextEdit {
        let block = lineBlock(s, selection)
        let (blockLines, trailing) = lines(s, block)
        let body = blockLines.joined(separator: "\n")
        let insert = trailing ? body + "\n" : "\n" + body
        let at = block.upperBound
        return TextEdit(range: NSRange(location: at, length: 0), replacement: insert,
                        selection: NSRange(location: selection.location + length(body) + 1, length: selection.length))
    }

    // MARK: Typing

    /// Return: keeps the current indentation, indents after an opening bracket (or `:` in
    /// Python/YAML), splits `{|}` onto three lines, and continues Markdown lists.
    static func newline(_ s: NSString, selection: NSRange, style: IndentStyle, language: Language) -> TextEdit {
        let lineStart = s.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = s.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let indent = String(leadingWhitespace(before))

        if language == .markdown, let item = listItem(before) {
            if item.isEmpty {
                // Return on an empty item ends the list.
                return TextEdit(range: NSRange(location: lineStart, length: selection.upperBound - lineStart), replacement: "",
                                selection: NSRange(location: lineStart, length: 0))
            }
            let insert = "\n" + item.continuation
            return TextEdit(range: selection, replacement: insert, selection: NSRange(location: selection.location + length(insert), length: 0))
        }

        let last = before.trimmingCharacters(in: .whitespaces).last
        let next: Character? = selection.upperBound < s.length ? Character(UnicodeScalar(s.character(at: selection.upperBound)) ?? " ") : nil
        var insert = "\n" + indent
        var caret = length(insert)
        let opens = last == "{" || last == "[" || last == "(" || (language.colonIndents && last == ":")
        if opens {
            insert += style.unit
            caret = length(insert)
            if let next, let last, pairs[last] == next, next != last {
                insert += "\n" + indent
            }
        }
        return TextEdit(range: selection, replacement: insert, selection: NSRange(location: selection.location + caret, length: 0))
    }

    /// A Markdown list item's marker, and whether the item has any text yet.
    struct ListItem: Equatable { var continuation: String; var isEmpty: Bool }

    static func listItem(_ line: String) -> ListItem? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        let indent = String(chars[0..<i])
        var marker: String
        if i < chars.count, "-*+".contains(chars[i]) {
            marker = String(chars[i])
            i += 1
        } else {
            var j = i
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
            guard j > i, j < chars.count, chars[j] == "." || chars[j] == ")", let number = Int(String(chars[i..<j])) else { return nil }
            marker = "\(number + 1)\(chars[j])"
            i = j + 1
        }
        guard i < chars.count, chars[i] == " " else { return nil }
        i += 1
        var rest = String(chars[i...])
        var task = ""
        if rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
            task = "[ ] "
            rest = String(rest.dropFirst(4))
        }
        return ListItem(continuation: indent + marker + " " + task, isEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}", "\"", "'", "`"]

    /// Auto-pairing for one typed character. `nil` means "insert it normally".
    static func typing(_ text: String, in s: NSString, selection: NSRange, pairQuotes: Bool) -> TextEdit? {
        guard text.count == 1, let typed = text.first else { return nil }
        let isQuote = typed == "\"" || typed == "'" || typed == "`"
        if isQuote, !pairQuotes { return nil }
        let next = character(s, at: selection.upperBound)
        let prev = character(s, at: selection.location - 1)

        // Typing the closer that's already there just steps over it.
        if selection.length == 0, closers.contains(typed), next == typed {
            return TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: NSRange(location: selection.location + 1, length: 0))
        }
        guard let close = pairs[typed] else { return nil }
        if selection.length > 0 {
            let inner = s.substring(with: selection)
            return TextEdit(range: selection, replacement: String(typed) + inner + String(close),
                            selection: NSRange(location: selection.location + 1, length: selection.length))
        }
        // Only pair before whitespace or punctuation, so typing `(` in front of a word doesn't.
        if let next, !(next.isWhitespace || closers.contains(next) || next == "," || next == ";") { return nil }
        if isQuote, let prev, prev.isLetter || prev.isNumber || prev == typed || prev == "\\" { return nil }
        return TextEdit(range: selection, replacement: String(typed) + String(close), selection: NSRange(location: selection.location + 1, length: 0))
    }

    /// Backspace between an empty pair, `(|)`, deletes both halves.
    static func deleteBackward(_ s: NSString, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let prev = character(s, at: selection.location - 1), let close = pairs[prev],
              character(s, at: selection.location) == close else { return nil }
        return TextEdit(range: NSRange(location: selection.location - 1, length: 2), replacement: "", selection: NSRange(location: selection.location - 1, length: 0))
    }

    private static func character(_ s: NSString, at index: Int) -> Character? {
        guard index >= 0, index < s.length, let scalar = UnicodeScalar(s.character(at: index)) else { return nil }
        return Character(scalar)
    }

    // MARK: Brackets

    /// Index of the bracket matching the one at `index`, scanning at most `limit` characters
    /// so a stray brace in a huge file can't stall the caret.
    static func matchingBracket(in s: NSString, at index: Int, limit: Int = 100_000) -> Int? {
        guard index >= 0, index < s.length else { return nil }
        let open: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125]   // ( [ {
        let close: [UInt16: UInt16] = [41: 40, 93: 91, 125: 123]
        let c = s.character(at: index)
        let (partner, step): (UInt16, Int)
        if let p = open[c] { (partner, step) = (p, 1) } else if let p = close[c] { (partner, step) = (p, -1) } else { return nil }
        var depth = 0
        var i = index
        var scanned = 0
        while i >= 0, i < s.length, scanned < limit {
            let d = s.character(at: i)
            if d == c { depth += 1 } else if d == partner {
                depth -= 1
                if depth == 0 { return i }
            }
            i += step
            scanned += 1
        }
        return nil
    }

    // MARK: Markdown formatting

    /// ⌘B / ⌘I: wraps the selection in `marker`, or unwraps it if it's already wrapped.
    static func toggleWrap(_ s: NSString, selection: NSRange, marker: String) -> TextEdit {
        let m = length(marker)
        let selected = s.substring(with: selection)
        if selected.hasPrefix(marker), selected.hasSuffix(marker), selection.length >= 2 * m {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return TextEdit(range: selection, replacement: inner, selection: NSRange(location: selection.location, length: length(inner)))
        }
        if selection.location >= m, selection.upperBound + m <= s.length,
           s.substring(with: NSRange(location: selection.location - m, length: m)) == marker,
           s.substring(with: NSRange(location: selection.upperBound, length: m)) == marker {
            return TextEdit(range: NSRange(location: selection.location - m, length: selection.length + 2 * m), replacement: selected,
                            selection: NSRange(location: selection.location - m, length: selection.length))
        }
        return TextEdit(range: selection, replacement: marker + selected + marker, selection: NSRange(location: selection.location + m, length: selection.length))
    }

    /// ⌘K: turns the selection into a link and selects the part still to fill in.
    static func link(_ s: NSString, selection: NSRange) -> TextEdit {
        let selected = s.substring(with: selection)
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            return TextEdit(range: selection, replacement: "[](\(selected))", selection: NSRange(location: selection.location + 1, length: 0))
        }
        let text = selected.isEmpty ? "text" : selected
        let replacement = "[\(text)](https://)"
        if selected.isEmpty {
            return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: selection.location + 1, length: length(text)))
        }
        return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: selection.location + length(text) + 3, length: length("https://")))
    }
}
