import Testing
import UniformTypeIdentifiers
@testable import FolioKit

@Suite("FileKind")
struct FileKindTests {
    @Test("Maps common extensions to the right editor", arguments: [
        ("report.pdf", FileKind.pdf), ("memo.docx", .document), ("notes.rtf", .document),
        ("budget.xlsx", .spreadsheet), ("data.csv", .spreadsheet), ("photo.jpg", .image),
        ("shot.png", .image), ("readme.md", .code), ("main.swift", .code), ("config.json", .code),
        ("clip.mov", .media), ("song.mp3", .media),
    ])
    func mapsExtension(name: String, expected: FileKind) {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)!
        #expect(FileKind.kind(for: type) == expected)
    }

    @Test func htmlIsADocumentNotCode() {
        #expect(FileKind.kind(for: .html) == .document)
    }

    @Test func everyKindReadsSomething() {
        for kind in FileKind.allCases { #expect(!kind.readableTypes.isEmpty, "\(kind)") }
    }
}
