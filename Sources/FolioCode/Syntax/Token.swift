import Foundation

/// What a span of source text is, for coloring. Kept small on purpose: a restrained
/// palette reads better than a rainbow, and every lexer maps onto the same set.
nonisolated enum TokenKind: UInt8, Sendable, CaseIterable {
    case keyword, type, function, string, number, literal, comment
    /// Decorators, preprocessor directives, YAML anchors, HTML attribute names.
    case attribute
    /// JSON/YAML/CSS keys.
    case property
    /// `$shell`, `$php` variables.
    case variable
    /// Markup tags and CSS selectors.
    case tag
    /// Markdown.
    case heading, emphasis, link, code
    /// Markup punctuation that should recede (Markdown `**`, `>` and fences).
    case punctuation
}

/// A colored span inside one line, in UTF-16 offsets from the line start
/// (the same units `NSString` and TextKit use, so no conversion is needed).
nonisolated struct Token: Hashable, Sendable {
    var kind: TokenKind
    var start: Int
    var end: Int
}

/// Lexer state carried from the end of one line to the start of the next.
///
/// Highlighting is incremental because of this: after an edit we re-lex lines until the
/// state at a line start matches what it was before, then stop. Three bytes is enough for
/// every lexer here (mode, which delimiter, nesting depth) and keeps the per-line cache tiny.
nonisolated struct LexState: Hashable, Sendable {
    var mode: UInt8 = 0
    var detail: UInt8 = 0
    var depth: UInt8 = 0
    static let initial = LexState()
}

/// A line-at-a-time tokenizer. Implementations are value types with no shared state,
/// so they can run on any thread.
nonisolated protocol Lexer: Sendable {
    /// Tokenizes one line (without its newline) starting in `state`, returning the state at
    /// the end of the line. Pass `tokens: nil` when only the end state is needed; lexers skip
    /// keyword lookups then, which makes catching up on long files much cheaper.
    func lex(_ line: UnsafeBufferPointer<UInt16>, state: LexState, tokens: inout [Token]?) -> LexState
}

nonisolated extension Lexer {
    /// Tokenizes a whole string. Token offsets are relative to the start of `text`.
    /// Used by tests and by the Markdown preview's code blocks.
    func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var state = LexState.initial
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let units = Array(line.utf16)
            var tokens: [Token]? = []
            state = units.withUnsafeBufferPointer { lex($0, state: state, tokens: &tokens) }
            result += (tokens ?? []).map { Token(kind: $0.kind, start: $0.start + offset, end: $0.end + offset) }
            offset += units.count + 1
        }
        return result
    }
}

/// UTF-16 character classes shared by the lexers. ASCII-only tests, with anything
/// non-ASCII counted as a letter so identifiers in other scripts stay whole.
nonisolated enum Char {
    static func of(_ s: Unicode.Scalar) -> UInt16 { UInt16(s.value) }
    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isLetter(_ c: UInt16) -> Bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 || c >= 0x80 }
    static func isIdent(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) }
    static func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
    static func isHex(_ c: UInt16) -> Bool { isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) }
}

nonisolated extension UnsafeBufferPointer<UInt16> {
    /// Whether `pattern` occurs at `index`.
    func has(_ pattern: [UInt16], at index: Int) -> Bool {
        guard !pattern.isEmpty, index >= 0, index + pattern.count <= count else { return false }
        for k in 0..<pattern.count where self[index + k] != pattern[k] { return false }
        return true
    }

    /// First index ≥ `from` where `pattern` starts.
    func find(_ pattern: [UInt16], from: Int) -> Int? {
        guard let first = pattern.first, from <= count - pattern.count else { return nil }
        var i = from
        while i <= count - pattern.count {
            if self[i] == first, has(pattern, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// Index of the first non-space character at or after `from`.
    func skipSpaces(from: Int) -> Int {
        var i = from
        while i < count, Char.isSpace(self[i]) { i += 1 }
        return i
    }

    func string(_ range: Range<Int>) -> String {
        guard let base = baseAddress, !range.isEmpty else { return "" }
        return String(utf16CodeUnits: base + range.lowerBound, count: range.count)
    }
}

nonisolated extension String {
    var utf16Array: [UInt16] { Array(utf16) }
}
