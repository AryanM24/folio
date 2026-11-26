import AppKit

/// Colors only what's on screen, recoloring after every scroll and edit.
///
/// How it stays fast on big files:
/// - Colors are `NSLayoutManager` *temporary attributes*: never stored in the text, so they
///   don't touch undo or trigger relayout, and they're only computed for visible lines
///   (a screenful is ~60 lines, well under a millisecond).
/// - The lexer state at the start of every line is cached (`states`). To color line N we only
///   need its start state, catching up from the last valid line without allocating tokens.
///   An edit invalidates the cache from the edited line down; it's rebuilt lazily as far as
///   the visible area needs.
/// - Lines longer than ``maxLineLength`` (minified bundles) are left uncolored.
final class SyntaxHighlighter {
    private(set) var lines = LineIndex()
    private var states: [LexState] = [.initial]
    /// `states[0..<valid]` are correct.
    private var valid = 1
    private var lexer: any Lexer = PlainLexer()
    private var buffer = [UInt16](repeating: 0, count: 1024)
    private var noTokens: [Token]?

    static let maxLineLength = 20_000

    func reset(text: NSString, lexer: any Lexer) {
        self.lexer = lexer
        lines = LineIndex(text)
        states = Array(repeating: .initial, count: lines.count)
        valid = 1
    }

    func setLexer(_ lexer: any Lexer) {
        self.lexer = lexer
        valid = 1
    }

    /// Updates the line index and state cache for an edit. Call from
    /// `textStorage(_:didProcessEditing:…)` with the storage's own edited range and delta.
    func didEdit(_ text: NSString, editedRange: NSRange, delta: Int) {
        let (first, removed, inserted) = lines.apply(editedRange: editedRange, delta: delta, in: text)
        states.replaceSubrange(first + 1..<first + 1 + removed, with: repeatElement(LexState.initial, count: inserted))
        valid = min(valid, first + 1)
    }

    /// Tokens of one line, offsets relative to the line start.
    func tokens(forLine line: Int, in text: NSString) -> [Token] {
        guard line < lines.count else { return [] }
        catchUp(through: line, in: text)
        var tokens: [Token]? = []
        _ = withLine(line, in: text) { lexer.lex($0, state: states[line], tokens: &tokens) }
        return tokens ?? []
    }

    /// Recolors every line touching `range` (character offsets).
    func colorize(_ range: NSRange, in text: NSString, layoutManager: NSLayoutManager) {
        guard text.length > 0 else { return }
        let first = lines.line(containing: range.location)
        let last = lines.line(containing: min(range.upperBound, text.length))
        let start = lines.start(ofLine: first)
        let end = last + 1 < lines.count ? lines.start(ofLine: last + 1) : text.length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: start, length: end - start))
        for line in first...last {
            let lineStart = lines.start(ofLine: line)
            for token in tokens(forLine: line, in: text) {
                guard let color = CodeTheme.color(for: token.kind) else { continue }
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color,
                                                    forCharacterRange: NSRange(location: lineStart + token.start, length: token.end - token.start))
            }
        }
    }

    private func catchUp(through line: Int, in text: NSString) {
        while valid <= line, valid < lines.count {
            states[valid] = withLine(valid - 1, in: text) { lexer.lex($0, state: states[valid - 1], tokens: &noTokens) } ?? states[valid - 1]
            valid += 1
        }
    }

    /// Runs `body` on the line's UTF-16 units. `nil` for over-long lines, which are skipped
    /// (their state passes through unchanged).
    private func withLine<R>(_ line: Int, in text: NSString, _ body: (UnsafeBufferPointer<UInt16>) -> R) -> R? {
        let range = lines.contentRange(ofLine: line, length: text.length)
        guard range.length <= Self.maxLineLength, range.upperBound <= text.length else { return nil }
        if buffer.count < range.length { buffer = [UInt16](repeating: 0, count: range.length) }
        return buffer.withUnsafeMutableBufferPointer { b -> R? in
            guard let base = b.baseAddress else { return nil }
            text.getCharacters(base, range: range)
            return body(UnsafeBufferPointer(start: base, count: range.length))
        }
    }
}
