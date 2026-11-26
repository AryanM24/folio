import AppKit  // Not Foundation: the Command Line Tools lack its Testing overlay.
import Testing

@testable import FolioCode

@Suite("Incremental highlighting")
@MainActor
struct HighlighterTests {
    private func allTokens(_ highlighter: SyntaxHighlighter, _ text: NSString) -> [[Token]] {
        (0..<highlighter.lines.count).map { highlighter.tokens(forLine: $0, in: text) }
    }

    @Test(
        "Edits give the same tokens as lexing from scratch",
        arguments: [
            (0, 0, "/* "), (12, 0, "\"open"), (3, 5, ""), (0, 0, "line\n\n"), (20, 4, "*/ x\n"),
        ])
    func editsMatchFreshLex(location: Int, length: Int, replacement: String) {
        let text = NSMutableString(string: "let a = 1\nvar b = \"s\"\n/* c */ let d\nfunc e() {}\n")
        let highlighter = SyntaxHighlighter()
        highlighter.reset(text: text, lexer: Language.swift.lexer)
        _ = allTokens(highlighter, text)  // Warm the state cache so the edit must invalidate it.

        let range = NSRange(location: location, length: length)
        text.replaceCharacters(in: range, with: replacement)
        let edited = NSRange(location: location, length: (replacement as NSString).length)
        highlighter.didEdit(text, editedRange: edited, delta: edited.length - length)

        let fresh = SyntaxHighlighter()
        fresh.reset(text: text, lexer: Language.swift.lexer)
        #expect(allTokens(highlighter, text) == allTokens(fresh, text))
    }

    @Test func overlongLinesAreSkipped() {
        let text = NSString(string: String(repeating: "a", count: SyntaxHighlighter.maxLineLength + 1) + "\nlet x")
        let highlighter = SyntaxHighlighter()
        highlighter.reset(text: text, lexer: Language.swift.lexer)
        #expect(highlighter.tokens(forLine: 0, in: text).isEmpty)
        #expect(highlighter.tokens(forLine: 1, in: text).map(\.kind) == [.keyword])
    }
}

@Suite("Editor helpers")
struct EditorHelperTests {
    @Test func matchesBrackets() {
        let s = "f(a[1], { b })" as NSString
        #expect(TextEditing.matchingBracket(in: s, at: 1) == 13)
        #expect(TextEditing.matchingBracket(in: s, at: 13) == 1)
        #expect(TextEditing.matchingBracket(in: s, at: 3) == 5)
        #expect(TextEditing.matchingBracket(in: s, at: 8) == 12)
        #expect(TextEditing.matchingBracket(in: s, at: 0) == nil)
        #expect(TextEditing.matchingBracket(in: "((" as NSString, at: 0) == nil)
    }

    @Test func countsWordsAndCharacters() {
        #expect(TextStats.count("Hello,  world\nagain 👋🏽") == (4, 21))
        #expect(TextStats.count("") == (0, 0))
    }
}

@Suite("File tools")
struct CodeToolTests {
    private func temporaryFile(_ name: String, _ bytes: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FolioCodeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try bytes.write(to: url)
        return url
    }

    @Test func toolIDsFollowTheConvention() {
        #expect(CodeTools.all.count == 6)
        #expect(CodeTools.all.allSatisfy { $0.id.hasPrefix("code.") })
        #expect(Set(CodeTools.all.map(\.id)).count == CodeTools.all.count)
    }

    @Test func formatJSONWritesANewFileAndKeepsTheInput() async throws {
        let input = try temporaryFile("data.json", Data(#"{"b":[1,2],"a":true}"#.utf8))
        let outputs = try await CodeTools.formatJSON.run([input], ["indent": "2"])
        #expect(outputs.first?.lastPathComponent == "data (formatted).json")
        #expect(try String(contentsOf: outputs[0], encoding: .utf8) == "{\n  \"b\": [\n    1,\n    2\n  ],\n  \"a\": true\n}\n")
        #expect(try String(contentsOf: input, encoding: .utf8) == #"{"b":[1,2],"a":true}"#)
    }

    @Test func formatJSONExplainsInvalidInput() async throws {
        let input = try temporaryFile("bad.json", Data("{\"a\": }".utf8))
        await #expect(throws: (any Error).self) { try await CodeTools.formatJSON.run([input], [:]) }
    }

    @Test func convertsLineEndingsAndEncoding() async throws {
        let input = try temporaryFile("note.txt", Data([0x43, 0x61, 0x66, 0xE9, 0x0A]))  // "Café\n", Latin-1
        let crlf = try await CodeTools.convertLineEndings.run([input], ["ending": "crlf"])
        #expect(try Data(contentsOf: crlf[0]) == Data([0x43, 0x61, 0x66, 0xE9, 0x0D, 0x0A]))
        let utf8 = try await CodeTools.convertToUTF8.run([input], [:])
        #expect(try Data(contentsOf: utf8[0]) == Data("Café\n".utf8))
    }

    @Test func markdownToHTMLRendersAStandalonePage() async throws {
        let input = try temporaryFile("Read Me.md", Data("# Hi\n\n*there*".utf8))
        let outputs = try await CodeTools.markdownToHTML.run([input], [:])
        let html = try String(contentsOf: outputs[0], encoding: .utf8)
        #expect(outputs[0].lastPathComponent == "Read Me.html")
        #expect(html.contains("<h1 data-line=\"0\" id=\"hi\">Hi</h1>"))
        #expect(html.contains("<title>Read Me</title>"))
    }

    @Test @MainActor func markdownExportsToWordAndPDF() throws {
        let docx = try MarkdownExport.docx(markdown: "# Title\n\nBody **bold**", title: "T")
        #expect(docx.starts(with: [0x50, 0x4B]))  // A zip container.
        let pdf = try MarkdownExport.pdf(markdown: "# Title\n\n" + String(repeating: "Paragraph text.\n\n", count: 200), title: "T")
        #expect(pdf.starts(with: Array("%PDF".utf8)))
    }
}
