import FolioKit
import Testing
import UniformTypeIdentifiers

@testable import FolioPreview

@Suite("Preview", .timeLimit(.minutes(1)))
struct PreviewDocumentTests {
    @Test("Opens the preview kind's types, including iWork files without iWork installed")
    func opensPreviewTypes() throws {
        #expect(PreviewDocument.readableContentTypes == FileKind.preview.readableTypes)
        let pages = try #require(UTType(filenameExtension: "pages"))
        #expect(PreviewDocument.readableContentTypes.contains { pages.conforms(to: $0) })
    }
}
