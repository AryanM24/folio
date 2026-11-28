import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import Testing
import UniformTypeIdentifiers

@testable import FolioKit

@Suite("FileKind", .timeLimit(.minutes(1)))
struct FileKindTests {
    @Test(
        "Maps common extensions to the right editor",
        arguments: [
            ("report.pdf", FileKind.pdf), ("memo.docx", .document), ("notes.rtf", .document),
            ("budget.xlsx", .spreadsheet), ("data.csv", .spreadsheet), ("photo.jpg", .image),
            ("shot.png", .image), ("readme.md", .code), ("main.swift", .code), ("config.json", .code),
            ("clip.mov", .media), ("song.mp3", .media),
            // 0.3 additions, with types macOS declares itself (imported ones need the app's Info.plist).
            ("book.epub", .document), ("mail.eml", .document), ("old.xls", .spreadsheet), ("invite.ics", .spreadsheet),
            ("card.vcf", .spreadsheet), ("shot.dng", .image), ("art.psd", .image), ("sky.exr", .image),
            ("song.ogg", .media), ("clip.webm", .media), ("captions.vtt", .code), ("map.geojson", .code),
            ("files.zip", .archive), ("logs.tgz", .archive), ("disk.iso", .archive), ("src.7z", .archive),
            ("deck.pptx", .preview), ("report.pages", .preview), ("font.ttf", .preview), ("scene.usda", .preview),
            ("part.stl", .preview), ("logo.ai", .preview), ("figure.eps", .preview),
        ])
    func mapsExtension(name: String, expected: FileKind) {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)!
        #expect(FileKind.kind(for: type) == expected, "\(name)")
    }

    @Test func htmlIsADocumentNotCode() {
        #expect(FileKind.kind(for: .html) == .document)
    }

    @Test func everyKindReadsSomething() {
        for kind in FileKind.allCases { #expect(!kind.readableTypes.isEmpty, "\(kind)") }
    }

    /// `make check-plist`: the document types in Info.plist are exactly FileKind's (plus Folio's
    /// own exported types), and every type macOS doesn't declare is imported there.
    @Test("Info.plist declares exactly FileKind's types")
    func plistAgrees() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let documentTypes = plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let declared = Set(documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        func identifiers(_ key: String) -> Set<String> {
            Set((plist[key] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String })
        }
        let exported = identifiers("UTExportedTypeDeclarations")
        let imported = identifiers("UTImportedTypeDeclarations")
        let kinds = Set(FileKind.allCases.flatMap(\.readableTypes).map(\.identifier))

        #expect(kinds.subtracting(declared).sorted() == [], "in FileKind, missing from CFBundleDocumentTypes")
        #expect(declared.subtracting(kinds).subtracting(exported).sorted() == [], "in CFBundleDocumentTypes, missing from FileKind")
        #expect(exported == [UTType.folioVideoProject.identifier, UTType.folioImageDocument.identifier])
        // Unit tests run without the app's Info.plist, so an undeclared type resolves to nil here.
        let undeclared = kinds.filter { UTType($0) == nil }
        #expect(undeclared.subtracting(imported).sorted() == [], "dynamic on this macOS and not imported")
    }
}
