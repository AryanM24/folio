import Foundation

/// HTML, XML, SVG and property lists.
///
/// Modes: 0 text, 1 inside a tag (between `<name` and `>`), 2 inside `<!-- … -->`,
/// 3 inside a quoted attribute value (detail = the quote). Tags and attribute values
/// often wrap across lines, so all of these carry over.
nonisolated struct MarkupLexer: Lexer {
    private enum Mode { static let text: UInt8 = 0, tag: UInt8 = 1, comment: UInt8 = 2, value: UInt8 = 3 }
    private static let commentOpen = "<!--".utf16Array, commentClose = "-->".utf16Array, cdataOpen = "<![CDATA[".utf16Array,
        cdataClose = "]]>".utf16Array

    func lex(_ s: UnsafeBufferPointer<UInt16>, state: LexState, tokens: inout [Token]?) -> LexState {
        let n = s.count
        var i = 0
        var mode = state.mode
        func emit(_ kind: TokenKind, _ a: Int, _ b: Int) {
            if tokens != nil, b > a { tokens?.append(Token(kind: kind, start: a, end: b)) }
        }

        if mode == Mode.comment {
            guard let end = s.find(Self.commentClose, from: 0) else { emit(.comment, 0, n); return state }
            emit(.comment, 0, end + 3)
            i = end + 3
            mode = Mode.text
        } else if mode == Mode.value {
            let quote = UInt16(state.detail)
            var j = 0
            while j < n, s[j] != quote { j += 1 }
            guard j < n else { emit(.string, 0, n); return state }
            emit(.string, 0, j + 1)
            i = j + 1
            mode = Mode.tag
        }

        while i < n {
            let c = s[i]
            if mode == Mode.tag {
                if Char.isSpace(c) || c == Char.of("=") { i += 1; continue }
                if c == Char.of(">") { emit(.tag, i, i + 1); i += 1; mode = Mode.text; continue }
                if (c == Char.of("/") || c == Char.of("?")), i + 1 < n, s[i + 1] == Char.of(">") {
                    emit(.tag, i, i + 2); i += 2; mode = Mode.text; continue
                }
                if c == Char.of("\"") || c == Char.of("'") {
                    var j = i + 1
                    while j < n, s[j] != c { j += 1 }
                    guard j < n else { emit(.string, i, n); return LexState(mode: Mode.value, detail: UInt8(c)) }
                    emit(.string, i, j + 1)
                    i = j + 1
                    continue
                }
                let j = scanName(s, from: i)
                if j > i { emit(.attribute, i, j); i = j } else { i += 1 }
                continue
            }

            // Text content.
            if c == Char.of("<") {
                if s.has(Self.commentOpen, at: i) {
                    guard let end = s.find(Self.commentClose, from: i + 4) else {
                        emit(.comment, i, n); return LexState(mode: Mode.comment)
                    }
                    emit(.comment, i, end + 3)
                    i = end + 3
                    continue
                }
                if s.has(Self.cdataOpen, at: i) {
                    let end = s.find(Self.cdataClose, from: i).map { $0 + 3 } ?? n
                    emit(.string, i, end)
                    i = end
                    continue
                }
                var j = i + 1
                if j < n, s[j] == Char.of("/") || s[j] == Char.of("!") || s[j] == Char.of("?") { j += 1 }
                let nameEnd = scanName(s, from: j)
                if nameEnd > j {
                    emit(s[i + 1] == Char.of("!") || s[i + 1] == Char.of("?") ? .attribute : .tag, i, nameEnd)
                    i = nameEnd
                    mode = Mode.tag
                    continue
                }
                i += 1
                continue
            }
            if c == Char.of("&") {
                var j = i + 1
                while j < n, j - i < 12, Char.isIdent(s[j]) || s[j] == Char.of("#") { j += 1 }
                if j < n, s[j] == Char.of(";"), j > i + 1 {
                    emit(.literal, i, j + 1)
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return LexState(mode: mode)
    }

    /// Tag and attribute names: letters, digits, `-`, `_`, `:`, `.`.
    private func scanName(_ s: UnsafeBufferPointer<UInt16>, from: Int) -> Int {
        var j = from
        while j < s.count, Char.isIdent(s[j]) || s[j] == Char.of("-") || s[j] == Char.of(":") || s[j] == Char.of(".") { j += 1 }
        return j
    }
}
