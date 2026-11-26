import AppKit
import Testing

@testable import FolioKit

/// New files and duplicates never overwrite: names count up the way Finder's do.
@Suite struct UniqueNameTests {
    @Test func countsUpPastExistingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "folio-unique-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FolioTool.unique(in: dir, name: "Untitled document", ext: "docx")
        #expect(first.lastPathComponent == "Untitled document.docx")
        try Data().write(to: first)
        #expect(FolioTool.unique(in: dir, name: "Untitled document", ext: "docx").lastPathComponent == "Untitled document 2.docx")
    }

    @Test func folderNamesHaveNoTrailingDot() throws {
        let dir = FileManager.default.temporaryDirectory
        #expect(FolioTool.unique(in: dir, name: "folio-\(UUID().uuidString)", ext: "").pathExtension.isEmpty)
    }
}
