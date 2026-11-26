import Testing
@testable import FolioSheets

@Test func documentStartsEmpty() {
    #expect(SpreadsheetDocument().data.isEmpty)
}
