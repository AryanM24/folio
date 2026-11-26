import PDFKit
import Testing

@testable import FolioPDF

/// The workspace writes this to disk for "New PDF", so it must reopen cleanly.
@Suite struct EmptyFileTests {
    @Test func emptyPDFHasOneBlankPage() throws {
        let pdf = try #require(PDFDocument(data: PDFFileDocument.emptyFileData()))
        #expect(pdf.pageCount == 1)
        #expect((pdf.page(at: 0)?.string ?? "").isEmpty)
    }
}
