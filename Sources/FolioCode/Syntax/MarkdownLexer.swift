import Foundation

/// Markdown source coloring: headings, list markers, code, links and emphasis markers.
///
/// Colors only; fonts stay monospaced and uniform so the source lines up. Structure
/// characters (`**`, `>`, fences) are dimmed so the prose reads first. Mode 1 is
/// "inside a fenced code block" (detail = fence character, depth = fence length).
nonisolated struct MarkdownLexer: Lexer {
    func lex(_ s: UnsafeBufferPointer<UInt16>, state: LexState, tokens: inout [Token]?) -> LexState {
        let n = s.count
        func emit(_ kind: TokenKind, _ a: Int, _ b: Int) {
            if tokens != nil, b > a { tokens?.append(Token(kind: kind, start: a, end: b)) }
        }
        var i = s.skipSpaces(from: 0)

        if state.mode == 1 {
            let fence = UInt16(state.detail)
            var j = i
            while j < n, s[j] == fence { j += 1 }
            if j - i >= Int(state.depth), s.skipSpaces(from: j) == n {
                emit(.punctuation, 0, n)
                return .initial
            }
            emit(.code, 0, n)
            return state
        }
        guard i < n else { return .initial }
        let c = s[i]

        // Fences.
        if c == Char.of("`") || c == Char.of("~"), i <= 3 {
            var j = i
            while j < n, s[j] == c { j += 1 }
            if j - i >= 3 {
                emit(.punctuation, i, j)
                emit(.attribute, s.skipSpaces(from: j), n)
                return LexState(mode: 1, detail: UInt8(c), depth: UInt8(min(j - i, 255)))
            }
        }
        // ATX headings.
        if c == Char.of("#") {
            var j = i
            while j < n, s[j] == c { j += 1 }
            if j - i <= 6, j == n || Char.isSpace(s[j]) {
                emit(.heading, i, n)
                return .initial
            }
        }
        // Thematic breaks and setext underlines.
        if c == Char.of("-") || c == Char.of("*") || c == Char.of("_") || c == Char.of("=") {
            var j = i, count = 0
            while j < n, s[j] == c || Char.isSpace(s[j]) { if s[j] == c { count += 1 }; j += 1 }
            if j == n, count >= 3 || (c == Char.of("=") && count >= 1) {
                emit(.punctuation, i, n)
                return .initial
            }
        }
        // Block quotes (possibly nested).
        while i < n, s[i] == Char.of(">") {
            emit(.punctuation, i, i + 1)
            i = s.skipSpaces(from: i + 1)
        }
        // List markers and task boxes.
        if i < n {
            var j = i
            if s[j] == Char.of("-") || s[j] == Char.of("*") || s[j] == Char.of("+") {
                j += 1
            } else {
                while j < n, Char.isDigit(s[j]) { j += 1 }
                if j > i, j < n, s[j] == Char.of(".") || s[j] == Char.of(")") { j += 1 } else { j = i }
            }
            if j > i, j == n || Char.isSpace(s[j]) {
                emit(.keyword, i, j)
                i = s.skipSpaces(from: j)
                if i + 2 < n, s[i] == Char.of("["), s[i + 2] == Char.of("]"), " xX".utf16.contains(s[i + 1]) {
                    emit(.keyword, i, i + 3)
                    i += 3
                }
            }
        }
        if tokens != nil { inline(s, from: i, emit: emit) }
        return .initial
    }

    /// Code spans, links, autolinks and emphasis markers within a line.
    private func inline(_ s: UnsafeBufferPointer<UInt16>, from: Int, emit: (TokenKind, Int, Int) -> Void) {
        let n = s.count
        var i = from
        while i < n {
            let c = s[i]
            switch c {
            case Char.of("\\"):
                i += 2
            case Char.of("`"):
                var run = i
                while run < n, s[run] == c { run += 1 }
                let fence = [UInt16](repeating: c, count: run - i)
                if let close = s.find(fence, from: run) {
                    emit(.code, i, close + fence.count)
                    i = close + fence.count
                } else {
                    i = run
                }
            case Char.of("["), Char.of("!"):
                let open = c == Char.of("!") ? i + 1 : i
                guard open < n, s[open] == Char.of("["), let close = matching(s, from: open, open: Char.of("["), close: Char.of("]")) else {
                    i += 1; continue
                }
                emit(.link, i, close + 1)
                i = close + 1
                if i < n, s[i] == Char.of("("), let end = matching(s, from: i, open: Char.of("("), close: Char.of(")")) {
                    emit(.punctuation, i, end + 1)
                    i = end + 1
                } else if i < n, s[i] == Char.of("["), let end = matching(s, from: i, open: Char.of("["), close: Char.of("]")) {
                    emit(.punctuation, i, end + 1)
                    i = end + 1
                } else if i < n, s[i] == Char.of(":") {
                    emit(.punctuation, i, n)
                    i = n
                }
            case Char.of("<"):
                var j = i + 1
                while j < n, s[j] != Char.of(">"), !Char.isSpace(s[j]) { j += 1 }
                if j < n, s[j] == Char.of(">"), j > i + 1 {
                    let inner = s.string(i + 1..<j)
                    emit(inner.contains(":") || inner.contains("@") ? .link : .tag, i, j + 1)
                    i = j + 1
                } else {
                    i += 1
                }
            case Char.of("*"), Char.of("_"), Char.of("~"):
                var j = i
                while j < n, s[j] == c { j += 1 }
                // `snake_case` words aren't emphasis.
                let intraword = c == Char.of("_") && i > 0 && Char.isIdent(s[i - 1]) && j < n && Char.isIdent(s[j])
                if !intraword, c != Char.of("~") || j - i == 2 { emit(.punctuation, i, j) }
                i = j
            default:
                i += 1
            }
        }
    }

    private func matching(_ s: UnsafeBufferPointer<UInt16>, from: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var j = from
        while j < s.count {
            let c = s[j]
            if c == Char.of("\\") { j += 2; continue }
            if c == open { depth += 1 } else if c == close { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }
}

/// Plain text: nothing to color.
nonisolated struct PlainLexer: Lexer {
    func lex(_ line: UnsafeBufferPointer<UInt16>, state: LexState, tokens: inout [Token]?) -> LexState { .initial }
}
