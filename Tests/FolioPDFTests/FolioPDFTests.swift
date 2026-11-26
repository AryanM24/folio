import Testing
@testable import FolioPDF

@Test func documentStartsEmpty() {
    #expect(PDFFileDocument().data.isEmpty)
}
