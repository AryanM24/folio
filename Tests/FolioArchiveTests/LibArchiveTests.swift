import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import CArchive
import FolioKit
import Testing

@testable import FolioArchive

@Suite("libarchive", .timeLimit(.minutes(1)))
struct LibArchiveTests {
    @Test("The system libarchive links: a zip written here lists its entries back")
    func listsAZipItWrote() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let names = ["hello.txt", "folder/notes.md"]

        let writer = try #require(archive_write_new())
        #expect(archive_write_set_format_by_name(writer, "zip") == ARCHIVE_OK)
        #expect(archive_write_open_filename(writer, url.path) == ARCHIVE_OK)
        for name in names {
            let body = Array("contents of \(name)\n".utf8)
            let entry = try #require(archive_entry_new())
            archive_entry_set_pathname(entry, name)
            archive_entry_set_size(entry, Int64(body.count))
            archive_entry_set_filetype(entry, 0o100000)  // AE_IFREG
            archive_entry_set_perm(entry, 0o644)
            #expect(archive_write_header(writer, entry) == ARCHIVE_OK)
            #expect(archive_write_data(writer, body, body.count) == body.count)
            archive_entry_free(entry)
        }
        #expect(archive_write_close(writer) == ARCHIVE_OK)
        archive_write_free(writer)

        let reader = try #require(archive_read_new())
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        #expect(archive_read_open_filename(reader, url.path, 16_384) == ARCHIVE_OK)
        var listed: [String] = []
        var entry: OpaquePointer?
        while archive_read_next_header(reader, &entry) == ARCHIVE_OK {
            listed.append(String(cString: archive_entry_pathname(entry)))
        }
        #expect(listed == names)
    }

    @Test func opensArchiveTypes() {
        #expect(ArchiveDocument.readableContentTypes == FileKind.archive.readableTypes)
    }
}
