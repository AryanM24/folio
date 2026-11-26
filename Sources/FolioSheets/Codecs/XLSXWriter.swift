public import Foundation

/// Writes a minimal, valid .xlsx that Excel, Numbers and Google Sheets open without
/// repair prompts: shared strings, numbers, booleans, errors, formulas with cached
/// values (so viewers that don't recalculate still show results), styles, column
/// widths, frozen panes and the active sheet.
public nonisolated enum XLSXWriter {
    /// - Parameter formulaValue: the computed value of a formula cell, for the cache.
    public static func write(_ wb: Workbook, formulaValue: (Int, CellRef) -> CellValue?) throws -> Data {
        var strings = SharedStrings()
        var styles = StyleTable()
        var sheetParts: [Data] = []
        for sheet in wb.sheets {
            sheetParts.append(Data(sheetXML(sheet, strings: &strings, styles: &styles) { formulaValue(sheet.id, $0) }.utf8))
        }
        var parts: [(path: String, data: Data, stored: Bool)] = [
            ("[Content_Types].xml", Data(contentTypes(wb.sheets.count).utf8), false),
            ("_rels/.rels", Data(rootRels.utf8), false),
            ("xl/workbook.xml", Data(workbookXML(wb).utf8), false),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels(wb.sheets.count).utf8), false),
            ("xl/styles.xml", Data(styles.xml.utf8), false),
            ("xl/sharedStrings.xml", Data(strings.xml.utf8), false),
        ]
        for (i, d) in sheetParts.enumerated() { parts.append(("xl/worksheets/sheet\(i + 1).xml", d, false)) }
        return try ZipPackage.write(parts)
    }

    private static func sheetXML(
        _ sheet: Sheet, strings: inout SharedStrings, styles: inout StyleTable, value: (CellRef) -> CellValue?
    ) -> String {
        var x = XMLText.header
        x +=
            "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        if let used = sheet.usedRange { x += "<dimension ref=\"\(used.a1)\"/>" }
        x += "<sheetViews><sheetView workbookViewId=\"0\">"
        if sheet.frozenRows > 0 || sheet.frozenCols > 0 {
            let topLeft = CellRef(row: sheet.frozenRows, col: sheet.frozenCols).a1
            let pane = sheet.frozenRows > 0 && sheet.frozenCols > 0 ? "bottomRight" : (sheet.frozenRows > 0 ? "bottomLeft" : "topRight")
            x += "<pane"
            if sheet.frozenCols > 0 { x += " xSplit=\"\(sheet.frozenCols)\"" }
            if sheet.frozenRows > 0 { x += " ySplit=\"\(sheet.frozenRows)\"" }
            x += " topLeftCell=\"\(topLeft)\" activePane=\"\(pane)\" state=\"frozen\"/>"
        }
        x += "</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/>"
        if !sheet.columnWidths.isEmpty {
            x += "<cols>"
            for (col, w) in sheet.columnWidths.sorted(by: { $0.key < $1.key }) {
                let chars = max(0, (w - 5) / 7)
                x += "<col min=\"\(col + 1)\" max=\"\(col + 1)\" width=\"\(String(format: "%.2f", chars))\" customWidth=\"1\"/>"
            }
            x += "</cols>"
        }
        x += "<sheetData>"
        var byRow: [Int: [Int]] = [:]
        for ref in sheet.cells.keys { byRow[ref.row, default: []].append(ref.col) }
        for ref in sheet.styles.keys where sheet.cells[ref] == nil { byRow[ref.row, default: []].append(ref.col) }
        for row in byRow.keys.sorted() {
            x += "<row r=\"\(row + 1)\">"
            for col in (byRow[row] ?? []).sorted() {
                let ref = CellRef(row: row, col: col)
                x += cellXML(ref, input: sheet[ref], styleID: styles.id(for: sheet.style(at: ref)), strings: &strings, value: value)
            }
            x += "</row>"
        }
        x += "</sheetData></worksheet>"
        return x
    }

    private static func cellXML(
        _ ref: CellRef, input: String, styleID: Int, strings: inout SharedStrings, value: (CellRef) -> CellValue?
    ) -> String {
        let s = styleID > 0 ? " s=\"\(styleID)\"" : ""
        let r = "<c r=\"\(ref.a1)\"\(s)"
        if input.isEmpty { return r + "/>" }
        if input.hasPrefix("=") {
            let f = "<f>" + XMLText.escape(String(input.dropFirst())) + "</f>"
            switch value(ref) ?? .empty {
            case .number(let n): return r + ">" + f + "<v>\(CellValue.plainNumberText(n))</v></c>"
            case .text(let t): return r + " t=\"str\">" + f + "<v>" + XMLText.escape(t) + "</v></c>"
            case .bool(let b): return r + " t=\"b\">" + f + "<v>\(b ? 1 : 0)</v></c>"
            case .error(let e): return r + " t=\"e\">" + f + "<v>" + XMLText.escape(e.rawValue) + "</v></c>"
            case .empty: return r + ">" + f + "</c>"
            }
        }
        switch CellValue.literal(input) {
        case .number(let n): return r + "><v>\(CellValue.plainNumberText(n))</v></c>"
        case .bool(let b): return r + " t=\"b\"><v>\(b ? 1 : 0)</v></c>"
        case .error(let e): return r + " t=\"e\"><v>" + XMLText.escape(e.rawValue) + "</v></c>"
        case .text(let t): return r + " t=\"s\"><v>\(strings.index(of: t))</v></c>"
        case .empty: return r + "/>"
        }
    }

    private static func workbookXML(_ wb: Workbook) -> String {
        var x = XMLText.header
        x +=
            "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        x += "<bookViews><workbookView activeTab=\"\(wb.activeSheetIndex)\"/></bookViews><sheets>"
        for (i, s) in wb.sheets.enumerated() {
            x += "<sheet name=\"\(XMLText.escape(s.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        return x + "</sheets><calcPr fullCalcOnLoad=\"1\"/></workbook>"
    }

    private static func workbookRels(_ count: Int) -> String {
        var x = XMLText.header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 1...max(1, count) {
            x +=
                "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }
        x +=
            "<Relationship Id=\"rId\(count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        x +=
            "<Relationship Id=\"rId\(count + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        return x + "</Relationships>"
    }

    private static let rootRels =
        XMLText.header
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        + "</Relationships>"

    private static func contentTypes(_ count: Int) -> String {
        var x = XMLText.header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        x += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        x += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        x +=
            "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in 1...max(1, count) {
            x +=
                "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        x +=
            "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        x +=
            "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
        return x + "</Types>"
    }
}

/// The shared string table: each distinct text stored once, referenced by index.
private nonisolated struct SharedStrings {
    private var order: [String] = []
    private var lookup: [String: Int] = [:]
    private var uses = 0

    mutating func index(of s: String) -> Int {
        uses += 1
        if let i = lookup[s] { return i }
        lookup[s] = order.count
        order.append(s)
        return order.count - 1
    }

    var xml: String {
        var x =
            XMLText.header
            + "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(uses)\" uniqueCount=\"\(order.count)\">"
        for s in order {
            let preserve = s.first?.isWhitespace == true || s.last?.isWhitespace == true || s.contains("\n")
            x += preserve ? "<si><t xml:space=\"preserve\">" : "<si><t>"
            x += XMLText.escape(s) + "</t></si>"
        }
        return x + "</sst>"
    }
}

/// Deduplicates cell styles into fonts, fills and cellXfs.
private nonisolated struct StyleTable {
    private var styles: [CellStyle] = [.plain]
    private var lookup: [CellStyle: Int] = [.plain: 0]

    mutating func id(for style: CellStyle) -> Int {
        if let i = lookup[style] { return i }
        lookup[style] = styles.count
        styles.append(style)
        return styles.count - 1
    }

    /// Custom number format ids start at 164 in OOXML.
    private static func numFmtID(_ f: NumberFormat) -> Int {
        switch f {
        case .general: 0
        case .number: 4
        case .currency: 164
        case .percent: 10
        case .date: 14
        }
    }

    var xml: String {
        var x = XMLText.header + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        x += "<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"&quot;$&quot;#,##0.00\"/></numFmts>"
        x += "<fonts count=\"\(styles.count)\">"
        for s in styles {
            x += "<font>"
            if s.bold { x += "<b/>" }
            if s.italic { x += "<i/>" }
            if s.underline { x += "<u/>" }
            x += "<sz val=\"11\"/>"
            if let c = s.textColor { x += "<color rgb=\"FF\(c.hexString)\"/>" }
            x += "<name val=\"Calibri\"/><family val=\"2\"/></font>"
        }
        x += "</fonts>"
        // Fills 0 and 1 are reserved by the spec (none, gray125).
        x +=
            "<fills count=\"\(styles.count + 2)\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
        for s in styles {
            if let f = s.fill {
                x +=
                    "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF\(f.hexString)\"/><bgColor indexed=\"64\"/></patternFill></fill>"
            } else {
                x += "<fill><patternFill patternType=\"none\"/></fill>"
            }
        }
        x += "</fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        x += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        x += "<cellXfs count=\"\(styles.count)\">"
        for (i, s) in styles.enumerated() {
            let fillID = s.fill == nil ? 0 : i + 2
            x += "<xf numFmtId=\"\(StyleTable.numFmtID(s.numberFormat))\" fontId=\"\(i)\" fillId=\"\(fillID)\" borderId=\"0\" xfId=\"0\""
            if s.numberFormat != .general { x += " applyNumberFormat=\"1\"" }
            if i > 0 { x += " applyFont=\"1\"" }
            if s.fill != nil { x += " applyFill=\"1\"" }
            if s.alignment != .automatic {
                x += " applyAlignment=\"1\"><alignment horizontal=\"\(s.alignment.rawValue)\"/></xf>"
            } else {
                x += "/>"
            }
        }
        x += "</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        return x + "</styleSheet>"
    }
}
