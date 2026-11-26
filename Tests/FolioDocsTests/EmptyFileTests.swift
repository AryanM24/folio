import AppKit
import Testing

@testable import FolioDocs

/// The workspace writes this to disk for "New document", so it must reopen cleanly.
@Suite struct EmptyFileTests {
    @Test func emptyDocxIsAZipThatReadsBackEmpty() throws {
        let data = RichTextDocument.emptyFileData()
        #expect(data.starts(with: Data("PK".utf8)))
        let (text, _) = try DocumentCodec.read(data, as: .docx)
        #expect(text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
