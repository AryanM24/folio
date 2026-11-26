import Foundation

/// YAML, TOML and INI: line-oriented `key: value` / `key = value` files.
///
/// These read best with keys, values and sections told apart, which a word-based lexer
/// can't do. The only multi-line construct handled is TOML's `"""` strings (mode 1).
nonisolated struct ConfigLexer: Lexer {
    enum Flavor: Sendable { case yaml, toml, ini }
    let flavor: Flavor

    private static let literals: Set<String> = [
        "true", "false", "null", "yes", "no", "on", "off", "True", "False", "Null", "NULL", "Yes", "No", "~",
    ]

    func lex(_ s: UnsafeBufferPointer<UInt16>, state: LexState, tokens: inout [Token]?) -> LexState {
        let n = s.count
        var i = 0
        func emit(_ kind: TokenKind, _ a: Int, _ b: Int) {
            if tokens != nil, b > a { tokens?.append(Token(kind: kind, start: a, end: b)) }
        }

        if state.mode == 1 {
            let quote = state.detail
            let close = [UInt16](repeating: UInt16(quote), count: 3)
            guard let end = s.find(close, from: 0) else { emit(.string, 0, n); return state }
            emit(.string, 0, end + 3)
            i = end + 3
        } else {
            i = s.skipSpaces(from: 0)
            guard i < n else { return .initial }
            let c = s[i]
            if c == Char.of("#") || (flavor == .ini && c == Char.of(";")) { emit(.comment, i, n); return .initial }
            if flavor == .yaml, s.has("---".utf16Array, at: i) || s.has("...".utf16Array, at: i), i == 0 {
                emit(.punctuation, 0, n)
                return .initial
            }
            if flavor != .yaml, c == Char.of("[") {
                var j = i
                while j < n, s[j] != Char.of("]") { j += 1 }
                while j < n, s[j] == Char.of("]") { j += 1 }
                emit(.keyword, i, j)
                i = j
            } else {
                if flavor == .yaml, c == Char.of("-"), i + 1 == n || Char.isSpace(s[i + 1]) {
                    emit(.punctuation, i, i + 1)
                    i = s.skipSpaces(from: i + 1)
                }
                if let separator = keySeparator(s, from: i) {
                    var keyEnd = separator
                    while keyEnd > i, Char.isSpace(s[keyEnd - 1]) { keyEnd -= 1 }
                    emit(.property, i, keyEnd)
                    i = separator + 1
                }
            }
        }
        return lexValue(s, from: i, tokens: &tokens)
    }

    /// Index of the `:` (YAML) or `=` (TOML/INI) that ends a key, ignoring quoted text.
    private func keySeparator(_ s: UnsafeBufferPointer<UInt16>, from: Int) -> Int? {
        var j = from
        var quote: UInt16?
        while j < s.count {
            let c = s[j]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == Char.of("\"") || c == Char.of("'") {
                quote = c
            } else if flavor == .yaml {
                if c == Char.of(":"), j + 1 == s.count || Char.isSpace(s[j + 1]) { return j }
                if c == Char.of("#"), j > from, Char.isSpace(s[j - 1]) { return nil }
            } else if c == Char.of("=") {
                return j
            }
            j += 1
        }
        return nil
    }

    private func lexValue(_ s: UnsafeBufferPointer<UInt16>, from: Int, tokens: inout [Token]?) -> LexState {
        let n = s.count
        var i = from
        func emit(_ kind: TokenKind, _ a: Int, _ b: Int) {
            if tokens != nil, b > a { tokens?.append(Token(kind: kind, start: a, end: b)) }
        }
        while i < n {
            let c = s[i]
            if Char.isSpace(c) || c == Char.of(",") || c == Char.of("[") || c == Char.of("]") || c == Char.of("{") || c == Char.of("}") {
                i += 1; continue
            }
            if c == Char.of("#") || (flavor == .ini && c == Char.of(";")), i == from || Char.isSpace(s[i - 1]) {
                emit(.comment, i, n)
                return .initial
            }
            if c == Char.of("\"") || c == Char.of("'") {
                if flavor == .toml, i + 2 < n, s[i + 1] == c, s[i + 2] == c {
                    let close = [c, c, c]
                    guard let end = s.find(close, from: i + 3) else {
                        emit(.string, i, n)
                        return LexState(mode: 1, detail: UInt8(c))
                    }
                    emit(.string, i, end + 3)
                    i = end + 3
                    continue
                }
                var j = i + 1
                while j < n, s[j] != c {
                    if s[j] == Char.of("\\"), c == Char.of("\"") { j += 1 }
                    j += 1
                }
                j = min(j + 1, n)
                emit(.string, i, j)
                i = j
                continue
            }
            if flavor == .yaml, c == Char.of("&") || c == Char.of("*") || c == Char.of("!"), i + 1 < n, !Char.isSpace(s[i + 1]) {
                var j = i + 1
                while j < n, !Char.isSpace(s[j]) { j += 1 }
                emit(.attribute, i, j)
                i = j
                continue
            }
            // A bare word: number, literal, or (INI) plain text.
            var j = i
            while j < n, !Char.isSpace(s[j]), s[j] != Char.of(","), s[j] != Char.of("]"), s[j] != Char.of("}") { j += 1 }
            if j == i { j += 1 }
            if tokens != nil {
                let first = s[i]
                if Char.isDigit(first) || ((first == Char.of("-") || first == Char.of("+")) && i + 1 < j && Char.isDigit(s[i + 1])) {
                    emit(.number, i, j)
                } else if Self.literals.contains(s.string(i..<j)) {
                    emit(.literal, i, j)
                } else if flavor == .ini {
                    emit(.string, i, j)
                }
            }
            i = j
        }
        return .initial
    }
}
