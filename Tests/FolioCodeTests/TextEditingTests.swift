import AppKit  // Not Foundation: the Command Line Tools lack its Testing overlay.
import Testing

@testable import FolioCode

/// Applies an edit to `text` and returns the result with `|` at the caret (or `[…]` around a selection).
private func apply(_ edit: TextEdit?, to text: String) -> String {
    guard let edit else { return "nil" }
    let s = NSMutableString(string: text)
    s.replaceCharacters(in: edit.range, with: edit.replacement)
    if edit.selection.length == 0 {
        s.insert("|", at: edit.selection.location)
    } else {
        s.insert("]", at: edit.selection.upperBound)
        s.insert("[", at: edit.selection.location)
    }
    return s as String
}

/// Parses `|` or `[…]` markers into text + selection.
private func parse(_ marked: String) -> (NSString, NSRange) {
    let s = NSMutableString(string: marked)
    let caret = s.range(of: "|")
    if caret.location != NSNotFound {
        s.deleteCharacters(in: caret)
        return (s, NSRange(location: caret.location, length: 0))
    }
    let open = s.range(of: "[")
    s.deleteCharacters(in: open)
    let close = s.range(of: "]")
    s.deleteCharacters(in: close)
    return (s, NSRange(location: open.location, length: close.location - open.location))
}

private let spaces4 = IndentStyle(usesTabs: false, width: 4)

@Suite("Editing commands")
struct TextEditingTests {
    @Test func indentAndOutdentLines() {
        var (s, sel) = parse("[a\nb]\nc")
        #expect(apply(TextEditing.indent(s, selection: sel, unit: "  "), to: s as String) == "[  a\n  b]\nc")
        (s, sel) = parse("    a|b")
        #expect(apply(TextEditing.outdent(s, selection: sel, width: 4), to: s as String) == "a|b")
        (s, sel) = parse("\tx|")
        #expect(apply(TextEditing.outdent(s, selection: sel, width: 4), to: s as String) == "x|")
    }

    @Test func tabInsertsToNextStopOrIndentsSelection() {
        var (s, sel) = parse("ab|")
        #expect(apply(TextEditing.tab(s, selection: sel, style: spaces4), to: s as String) == "ab  |")
        (s, sel) = parse("x|")
        #expect(apply(TextEditing.tab(s, selection: sel, style: IndentStyle(usesTabs: true, width: 4)), to: s as String) == "x\t|")
        (s, sel) = parse("[a\nb]")
        #expect(apply(TextEditing.tab(s, selection: sel, style: spaces4), to: s as String) == "[    a\n    b]")
    }

    @Test func toggleLineComments() {
        var (s, sel) = parse("[  a\n\n    b]")
        let commented = apply(TextEditing.toggleComment(s, selection: sel, lineComment: "//", blockComment: nil), to: s as String)
        #expect(commented == "[  // a\n\n  //   b]")
        (s, sel) = parse(commented)
        #expect(
            apply(TextEditing.toggleComment(s, selection: sel, lineComment: "//", blockComment: nil), to: s as String) == "[  a\n\n    b]")
        (s, sel) = parse("x = 1|")
        #expect(apply(TextEditing.toggleComment(s, selection: sel, lineComment: "#", blockComment: nil), to: s as String) == "# x = 1|")
    }

    @Test func toggleBlockComments() {
        let (s, sel) = parse("<p>hi</p>|")
        let wrapped = apply(TextEditing.toggleComment(s, selection: sel, lineComment: nil, blockComment: ("<!--", "-->")), to: s as String)
        #expect(wrapped == "<!-- <p>hi</p> -->|")
        let (s2, sel2) = parse(wrapped)
        #expect(
            apply(TextEditing.toggleComment(s2, selection: sel2, lineComment: nil, blockComment: ("<!--", "-->")), to: s2 as String)
                == "<p>hi</p>|")
    }

    @Test func moveLinesUpAndDown() {
        var (s, sel) = parse("a\nb|\nc")
        #expect(apply(TextEditing.moveLines(s, selection: sel, up: true), to: s as String) == "b|\na\nc")
        (s, sel) = parse("a|\nb\nc")
        #expect(apply(TextEditing.moveLines(s, selection: sel, up: false), to: s as String) == "b\na|\nc")
        (s, sel) = parse("a\nb\nc|")
        #expect(apply(TextEditing.moveLines(s, selection: sel, up: true), to: s as String) == "a\nc|\nb")
        (s, sel) = parse("a\nb|")
        #expect(TextEditing.moveLines(s, selection: sel, up: false) == nil)
        (s, sel) = parse("a|\nb")
        #expect(TextEditing.moveLines(s, selection: sel, up: true) == nil)
    }

    @Test func duplicateLines() {
        var (s, sel) = parse("a|b\nc")
        #expect(apply(TextEditing.duplicateLines(s, selection: sel), to: s as String) == "ab\na|b\nc")
        (s, sel) = parse("x|")
        #expect(apply(TextEditing.duplicateLines(s, selection: sel), to: s as String) == "x\nx|")
    }

    @Test func newlineKeepsAndAddsIndentation() {
        var (s, sel) = parse("    let x|")
        #expect(apply(TextEditing.newline(s, selection: sel, style: spaces4, language: .swift), to: s as String) == "    let x\n    |")
        (s, sel) = parse("func f() {|}")
        #expect(apply(TextEditing.newline(s, selection: sel, style: spaces4, language: .swift), to: s as String) == "func f() {\n    |\n}")
        (s, sel) = parse("def f():|")
        #expect(apply(TextEditing.newline(s, selection: sel, style: spaces4, language: .python), to: s as String) == "def f():\n    |")
        (s, sel) = parse("a:|")
        #expect(apply(TextEditing.newline(s, selection: sel, style: spaces4, language: .swift), to: s as String) == "a:\n|")
    }

    @Test func newlineContinuesMarkdownLists() {
        var (s, sel) = parse("- item|")
        #expect(apply(TextEditing.newline(s, selection: sel, style: spaces4, language: .markdown), to: s as String) == "- item\n- |")
        (s, sel) = parse("  9. nine|")
        #expect(apply(TextEditing.newline(s, selection: sel, style: spaces4, language: .markdown), to: s as String) == "  9. nine\n  10. |")
        (s, sel) = parse("- [x] done|")
        #expect(
            apply(TextEditing.newline(s, selection: sel, style: spaces4, language: .markdown), to: s as String) == "- [x] done\n- [ ] |")
        (s, sel) = parse("a\n- |")
        #expect(apply(TextEditing.newline(s, selection: sel, style: spaces4, language: .markdown), to: s as String) == "a\n|")
    }

    @Test func autoPairs() {
        var (s, sel) = parse("f|")
        #expect(apply(TextEditing.typing("(", in: s, selection: sel, pairQuotes: true), to: s as String) == "f(|)")
        (s, sel) = parse("(|)")
        #expect(apply(TextEditing.typing(")", in: s, selection: sel, pairQuotes: true), to: s as String) == "()|")
        (s, sel) = parse("[word]")
        #expect(apply(TextEditing.typing("\"", in: s, selection: sel, pairQuotes: true), to: s as String) == "\"[word]\"")
        (s, sel) = parse("|word")
        #expect(TextEditing.typing("(", in: s, selection: sel, pairQuotes: true) == nil)
        (s, sel) = parse("don|")
        #expect(TextEditing.typing("'", in: s, selection: sel, pairQuotes: true) == nil)
        (s, sel) = parse("say |")
        #expect(TextEditing.typing("\"", in: s, selection: sel, pairQuotes: false) == nil)
        (s, sel) = parse("[|]")
        #expect(apply(TextEditing.deleteBackward(s, selection: sel), to: s as String) == "|")
    }

    @Test func markdownWrapping() {
        var (s, sel) = parse("a [bold] c")
        let bold = apply(TextEditing.toggleWrap(s, selection: sel, marker: "**"), to: s as String)
        #expect(bold == "a **[bold]** c")
        (s, sel) = parse(bold)
        #expect(apply(TextEditing.toggleWrap(s, selection: sel, marker: "**"), to: s as String) == "a [bold] c")
        (s, sel) = parse("|")
        #expect(apply(TextEditing.toggleWrap(s, selection: sel, marker: "*"), to: s as String) == "*|*")
        (s, sel) = parse("[Folio]")
        #expect(apply(TextEditing.link(s, selection: sel), to: s as String) == "[Folio]([https://])")
    }
}
