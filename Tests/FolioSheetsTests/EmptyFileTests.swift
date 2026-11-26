import AppKit
import Testing

@testable import FolioSheets

/// The workspace writes this to disk for "New spreadsheet", so it must reopen cleanly.
@Suite struct EmptyFileTests {
    @Test func emptyXlsxReadsBackAsOneBlankSheet() throws {
        let data = try SpreadsheetDocument.emptyFileData()
        let workbook = try SpreadsheetFormat.xlsx.read(data)
        #expect(workbook.sheets.count == 1)
        #expect(workbook.sheets[0].cells.isEmpty)
    }
}
