import AppKit  // Not Foundation: the Command Line Tools lack its Testing overlay.
import Testing

@testable import FolioCode

@Suite("Encodings and line endings")
struct TextFormatTests {
    @Test(
        "Round-trips bytes exactly",
        arguments: [
            TextFormat(encoding: .utf8, lineEnding: .lf), TextFormat(encoding: .utf8, lineEnding: .crlf),
            TextFormat(encoding: .utf8BOM, lineEnding: .lf), TextFormat(encoding: .utf16LE, lineEnding: .crlf),
            TextFormat(encoding: .utf16BE, lineEnding: .lf), TextFormat(encoding: .windowsLatin1, lineEnding: .crlf),
            TextFormat(encoding: .utf8, lineEnding: .cr),
        ])
    func roundTrip(format: TextFormat) throws {
        let original = "Café — naïve\nsecond line\n\nlast without newline"
        let text = format.encoding == .windowsLatin1 ? original.replacingOccurrences(of: "—", with: "-") : original
        let data = try TextCodec.encode(text, as: format)
        let decoded = TextCodec.decode(data)
        #expect(decoded.text == text)
        #expect(decoded.format == format)
        #expect(try TextCodec.encode(decoded.text, as: decoded.format) == data)
    }

    @Test func keepsTrailingNewlineState() throws {
        for text in ["a\nb\n", "a\nb"] {
            let decoded = TextCodec.decode(Data(text.utf8))
            #expect(try TextCodec.encode(decoded.text, as: decoded.format) == Data(text.utf8))
        }
    }

    @Test func detectsCRLFAndNormalizesToLF() {
        let decoded = TextCodec.decode(Data("one\r\ntwo\r\n".utf8))
        #expect(decoded.format.lineEnding == .crlf)
        #expect(decoded.text == "one\ntwo\n")
    }

    @Test func invalidUTF8FallsBackToWindowsLatin() {
        let decoded = TextCodec.decode(Data([0x43, 0x61, 0x66, 0xE9]))  // "Café" in Latin-1
        #expect(decoded.text == "Café")
        #expect(decoded.format.encoding == .windowsLatin1)
    }

    @Test func detectsUTF16WithoutBOM() {
        let data = "hello world".data(using: .utf16LittleEndian) ?? Data()
        #expect(TextCodec.decode(data).text == "hello world")
        #expect(TextCodec.decode(data).format.encoding == .utf16LE)
    }

    @Test func refusesUnrepresentableCharacters() {
        #expect(throws: (any Error).self) {
            try TextCodec.encode("emoji 🎉", as: TextFormat(encoding: .isoLatin1, lineEnding: .lf))
        }
    }

    @Test func emptyFileIsUTF8LF() {
        #expect(TextCodec.decode(Data()).format == .standard)
    }

    @Test func detectsIndentation() {
        #expect(IndentStyle.detect(in: "a {\n  b {\n    c\n  }\n}") == IndentStyle(usesTabs: false, width: 2))
        #expect(IndentStyle.detect(in: "a\n\tb\n\t\tc") == IndentStyle(usesTabs: true, width: 4))
        #expect(IndentStyle.detect(in: "x:\n    y\n        z") == IndentStyle(usesTabs: false, width: 4))
        #expect(IndentStyle.detect(in: "flat\ntext") == nil)
    }
}

@Suite("Line index")
struct LineIndexTests {
    @Test func findsLines() {
        let index = LineIndex("ab\ncd\n\nef" as NSString)
        #expect(index.starts == [0, 3, 6, 7])
        #expect(index.line(containing: 0) == 0)
        #expect(index.line(containing: 2) == 0)
        #expect(index.line(containing: 3) == 1)
        #expect(index.line(containing: 9) == 3)
        #expect(index.contentRange(ofLine: 1, length: 9) == NSRange(location: 3, length: 2))
    }

    @Test(
        "Incremental edits match a full rescan",
        arguments: [
            (2, 0, "\n"), (0, 3, ""), (3, 4, "X\nY\nZ"), (9, 0, "\n\n"), (1, 1, "q"),
        ])
    func incrementalMatchesRescan(location: Int, length: Int, replacement: String) {
        let text = NSMutableString(string: "ab\ncd\n\nef")
        var index = LineIndex(text)
        text.replaceCharacters(in: NSRange(location: location, length: length), with: replacement)
        let edited = NSRange(location: location, length: (replacement as NSString).length)
        index.apply(editedRange: edited, delta: edited.length - length, in: text)
        #expect(index.starts == LineIndex(text).starts)
    }
}
