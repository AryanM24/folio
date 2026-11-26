import Foundation

/// The rules that distinguish one "programming language shaped" syntax from another.
///
/// C, Swift, JavaScript, Python, Ruby, shell, SQL, JSON and CSS all share the same
/// skeleton (comments, quoted strings, numbers, words), so one state machine
/// (``GenericLexer``) plus a table per language covers them. Adding a language is
/// usually just a new `Grammar` in `Grammars.swift`.
nonisolated struct Grammar: Sendable {
    var lineComments: [[UInt16]] = []
    var blockComment: (open: [UInt16], close: [UInt16])?
    /// Characters that open a string.
    var quotes: [UInt16] = [Char.of("\""), Char.of("'")]
    /// Quotes whose strings may continue onto the next line (template literals, shell).
    var multilineQuotes: Set<UInt16> = []
    /// Quotes without backslash escapes (shell `'…'`, Go raw strings).
    var rawQuotes: Set<UInt16> = []
    /// `"""` / `'''` strings that span lines (Python, Swift, Kotlin).
    var tripleQuotes = false
    var keywords: Set<String> = []
    var types: Set<String> = []
    var literals: Set<String> = []
    /// SQL and PHP keywords match regardless of case.
    var caseInsensitive = false
    /// `UpperCamelCase` words are types (Swift, Java, TypeScript…).
    var capitalizedTypes = false
    /// `@decorator`, Ruby `@ivar`, CSS `@media`.
    var attributePrefix: UInt16?
    /// `$name` (shell, PHP).
    var variablePrefix: UInt16?
    /// `#include`-style directives at line start.
    var preprocessor = false
    /// A string followed by `:` is a key (JSON).
    var keysBeforeColon = false
    /// `#` starts a comment only at a word boundary (shell: `a#b` is a word).
    var commentNeedsBoundary = false
    /// Ruby `:symbol`.
    var symbols = false
    /// Characters allowed inside identifiers besides letters and digits (`$` in JS, `-` in CSS).
    var identifierExtras: Set<UInt16> = []
    /// CSS: track brace depth to tell selectors from properties.
    var css = false
}

/// Lexer for every language described by a ``Grammar``.
///
/// States: mode 0 is code (depth = CSS brace nesting), 1 is inside a block comment,
/// 2 is inside a string that continues onto the next line (detail = quote index,
/// high bit set for triple quotes).
nonisolated struct GenericLexer: Lexer {
    let grammar: Grammar

    private enum Mode { static let code: UInt8 = 0, comment: UInt8 = 1, string: UInt8 = 2 }

    func lex(_ s: UnsafeBufferPointer<UInt16>, state start: LexState, tokens: inout [Token]?) -> LexState {
        let g = grammar
        let n = s.count
        var i = 0
        var depth = start.depth
        let emitting = tokens != nil

        func emit(_ kind: TokenKind, _ a: Int, _ b: Int) {
            if emitting, b > a { tokens?.append(Token(kind: kind, start: a, end: b)) }
        }

        // Resume a construct left open on the previous line.
        if start.mode == Mode.comment, let close = g.blockComment?.close {
            guard let end = s.find(close, from: 0) else {
                emit(.comment, 0, n)
                return start
            }
            emit(.comment, 0, end + close.count)
            i = end + close.count
        } else if start.mode == Mode.string {
            let index = Int(start.detail & 0x7F)
            let triple = start.detail & 0x80 != 0
            guard index < g.quotes.count else { return LexState(depth: depth) }
            let quote = g.quotes[index]
            let (end, closed) = scanString(s, from: 0, quote: quote, triple: triple, escapes: !g.rawQuotes.contains(quote))
            emit(.string, 0, end)
            if !closed { return start }
            i = end
        }

        while i < n {
            let c = s[i]
            if Char.isSpace(c) { i += 1; continue }

            // Comments.
            if g.lineComments.contains(where: { s.has($0, at: i) }),
                !g.commentNeedsBoundary || i == 0 || Char.isSpace(s[i - 1])
            {
                emit(.comment, i, n)
                return LexState(depth: depth)
            }
            if let block = g.blockComment, s.has(block.open, at: i) {
                guard let end = s.find(block.close, from: i + block.open.count) else {
                    emit(.comment, i, n)
                    return LexState(mode: Mode.comment, depth: depth)
                }
                emit(.comment, i, end + block.close.count)
                i = end + block.close.count
                continue
            }

            // Strings.
            if let index = g.quotes.firstIndex(of: c) {
                let triple = g.tripleQuotes && i + 2 < n && s[i + 1] == c && s[i + 2] == c
                let (end, closed) = scanString(s, from: i + (triple ? 3 : 1), quote: c, triple: triple, escapes: !g.rawQuotes.contains(c))
                var kind = TokenKind.string
                if g.keysBeforeColon, closed {
                    let next = s.skipSpaces(from: end)
                    if next < n, s[next] == Char.of(":") { kind = .property }
                }
                emit(kind, i, end)
                if !closed, triple || g.multilineQuotes.contains(c) {
                    return LexState(mode: Mode.string, detail: UInt8(index) | (triple ? 0x80 : 0), depth: depth)
                }
                i = end
                continue
            }

            // Numbers (also CSS lengths like `12px` and `50%`).
            if Char.isDigit(c) || (c == Char.of(".") && i + 1 < n && Char.isDigit(s[i + 1]) && (i == 0 || !Char.isIdent(s[i - 1]))) {
                var j = i + 1
                while j < n {
                    let d = s[j]
                    if Char.isIdent(d) || d == Char.of(".") || d == Char.of("%") { j += 1; continue }
                    // Exponent sign: 1e-9, 2E+3 (not hex digits like 0xE).
                    if (d == Char.of("-") || d == Char.of("+")), j > i, s[j - 1] | 0x20 == Char.of("e"),
                        !(i + 1 < n && s[i + 1] | 0x20 == Char.of("x"))
                    {
                        j += 1; continue
                    }
                    break
                }
                emit(.number, i, j)
                i = j
                continue
            }

            // CSS: `.class` / `#id` selectors, `#fff` colors, braces.
            if g.css {
                if c == Char.of("{") { depth = depth < 255 ? depth + 1 : depth; i += 1; continue }
                if c == Char.of("}") { depth = depth > 0 ? depth - 1 : 0; i += 1; continue }
                if c == Char.of("#") || (c == Char.of(".") && depth == 0), i + 1 < n, Char.isIdent(s[i + 1]) || s[i + 1] == Char.of("-") {
                    let j = scanIdentifier(s, from: i + 1)
                    emit(depth > 0 && c == Char.of("#") ? .number : .type, i, j)
                    i = j
                    continue
                }
            }

            // `@decorator`, `$variable`, `#directive`, `:symbol`.
            if let prefix = g.attributePrefix, c == prefix, i + 1 < n, Char.isLetter(s[i + 1]) {
                let j = scanIdentifier(s, from: i + 1)
                emit(.attribute, i, j)
                i = j
                continue
            }
            if let prefix = g.variablePrefix, c == prefix, i + 1 < n {
                let j = scanVariable(s, from: i + 1)
                if j > i + 1 {
                    emit(.variable, i, j)
                    i = j
                    continue
                }
            }
            if g.preprocessor, c == Char.of("#"), s.skipSpaces(from: 0) == i {
                let j = scanIdentifier(s, from: s.skipSpaces(from: i + 1))
                emit(.attribute, i, j)
                i = j
                continue
            }
            if g.symbols, c == Char.of(":"), i + 1 < n, Char.isLetter(s[i + 1]),
                i == 0 || !(Char.isIdent(s[i - 1]) || s[i - 1] == Char.of(":"))
            {
                let j = scanIdentifier(s, from: i + 1)
                emit(.literal, i, j)
                i = j
                continue
            }

            // Words.
            if Char.isLetter(c) || g.identifierExtras.contains(c) {
                let j = scanIdentifier(s, from: i)
                if emitting, let kind = classify(s, i..<j, depth: depth) { emit(kind, i, j) }
                i = j
                continue
            }
            i += 1
        }
        return LexState(depth: depth)
    }

    /// Decides what a word is. Only runs when tokens are wanted.
    private func classify(_ s: UnsafeBufferPointer<UInt16>, _ range: Range<Int>, depth: UInt8) -> TokenKind? {
        let g = grammar
        let raw = s.string(range)
        let word = g.caseInsensitive ? raw.lowercased() : raw
        if g.keywords.contains(word) { return .keyword }
        if g.literals.contains(word) { return .literal }
        if g.types.contains(word) { return .type }
        let next = s.skipSpaces(from: range.upperBound)
        if g.css {
            if depth == 0 { return .tag }
            return next < s.count && s[next] == Char.of(":") ? .property : nil
        }
        if range.upperBound < s.count, s[range.upperBound] == Char.of("(") { return .function }
        if g.capitalizedTypes, Char.isUpper(s[range.lowerBound]) { return .type }
        return nil
    }

    private func scanIdentifier(_ s: UnsafeBufferPointer<UInt16>, from: Int) -> Int {
        var j = from
        while j < s.count, Char.isIdent(s[j]) || grammar.identifierExtras.contains(s[j]) { j += 1 }
        // Ruby predicates and bang methods: `empty?`, `save!`.
        if grammar.symbols, j < s.count, s[j] == Char.of("?") || s[j] == Char.of("!") { j += 1 }
        return j
    }

    /// `$name`, `${…}`, and shell specials like `$1`, `$@`, `$?`.
    private func scanVariable(_ s: UnsafeBufferPointer<UInt16>, from: Int) -> Int {
        guard from < s.count else { return from }
        let c = s[from]
        if c == Char.of("{") {
            var j = from + 1
            while j < s.count, s[j] != Char.of("}") { j += 1 }
            return min(j + 1, s.count)
        }
        if Char.isLetter(c) { return scanIdentifier(s, from: from) }
        if Char.isDigit(c) || "@?#*!$-".utf16.contains(c) { return from + 1 }
        return from
    }

    /// Scans to the closing quote. Returns the index after it, and whether it was found.
    private func scanString(_ s: UnsafeBufferPointer<UInt16>, from: Int, quote: UInt16, triple: Bool, escapes: Bool) -> (Int, Bool) {
        var j = from
        let n = s.count
        while j < n {
            let c = s[j]
            if escapes, c == Char.of("\\") { j += 2; continue }
            if c == quote {
                if !triple { return (j + 1, true) }
                if j + 2 < n, s[j + 1] == quote, s[j + 2] == quote { return (j + 3, true) }
            }
            j += 1
        }
        return (n, false)
    }
}
