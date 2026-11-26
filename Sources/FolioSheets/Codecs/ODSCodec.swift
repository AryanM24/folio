public import Foundation

/// OpenDocument spreadsheets (.ods, LibreOffice / Collabora).
///
/// Reads values, formulas (OpenFormula → A1 syntax), repeated rows and cells, and the
/// value types that imply a number format (date, percentage, currency). Writes values
/// and formulas; cell styles and column widths are not written to ODS yet.
public nonisolated enum ODSCodec {
    /// Repeats beyond this are almost always "the rest of the sheet is empty" padding.
    static let maxRepeat = 1024

    // MARK: Reading

    public static func read(_ data: Data) throws(FolioSheetsError) -> Workbook {
        let archive = try ZipPackage.open(data)
        guard let content = try ZipPackage.read(archive, "content.xml") else {
            throw .unreadableFile("This file doesn't contain any spreadsheet content.")
        }
        var sheets: [Sheet] = []
        var cells: [CellRef: String] = [:]
        var styles: [CellRef: CellStyle] = [:]
        var name = ""
        var row = 0, col = 0
        var rowRepeat = 1

        // Current cell.
        var inCell = false
        var cellRepeat = 1
        var valueType = ""
        var officeValue: String?
        var formula: String?
        var paragraphs: [String] = []
        var inParagraph = false
        var depth = 0  // nesting inside <table:table-cell> (subtables, annotations)
        var rowCells: [(col: Int, input: String, style: CellStyle?)] = []

        try XMLScanner.scan(
            content,
            start: { el, a in
                switch el {
                case "table":
                    if !inCell {
                        name = a["name"] ?? "Sheet \(sheets.count + 1)"
                        cells = [:]
                        styles = [:]
                        row = 0
                    }
                case "table-row":
                    guard !inCell else { return }
                    col = 0
                    rowCells = []
                    rowRepeat = min(max(1, a["number-rows-repeated"].flatMap(Int.init) ?? 1), 1_048_576)
                case "table-cell", "covered-table-cell":
                    guard !inCell else { depth += 1; return }
                    inCell = true
                    cellRepeat = min(max(1, a["number-columns-repeated"].flatMap(Int.init) ?? 1), 16384)
                    valueType = a["value-type"] ?? ""
                    switch valueType {
                    case "date": officeValue = a["date-value"]
                    case "time": officeValue = a["time-value"]
                    case "boolean": officeValue = a["boolean-value"]
                    default: officeValue = a["value"]
                    }
                    formula = a["formula"]
                    paragraphs = []
                case "p":
                    if inCell && depth == 0 { inParagraph = true; paragraphs.append("") }
                case "s":
                    if inParagraph { paragraphs[paragraphs.count - 1] += String(repeating: " ", count: a["c"].flatMap(Int.init) ?? 1) }
                case "tab":
                    if inParagraph { paragraphs[paragraphs.count - 1] += "\t" }
                case "line-break":
                    if inParagraph { paragraphs[paragraphs.count - 1] += "\n" }
                case "annotation":
                    if inCell { depth += 1 }
                default: break
                }
            },
            end: { el, _ in
                switch el {
                case "p": inParagraph = false
                case "annotation": if inCell { depth -= 1 }
                case "table-cell", "covered-table-cell":
                    if depth > 0 { depth -= 1; return }
                    inCell = false
                    let (input, style) = cellInput(
                        type: valueType, value: officeValue, formula: formula, text: paragraphs.joined(separator: "\n"))
                    if !input.isEmpty {
                        for k in 0..<min(cellRepeat, maxRepeat) { rowCells.append((col + k, input, style)) }
                    }
                    col += cellRepeat
                case "table-row":
                    guard !inCell else { return }
                    if !rowCells.isEmpty {
                        for k in 0..<min(rowRepeat, maxRepeat) {
                            for c in rowCells where c.col < 16384 {
                                let ref = CellRef(row: row + k, col: c.col)
                                // ODF formulas spell out absolute addresses, so a repeated row repeats them verbatim.
                                cells[ref] = c.input
                                if let s = c.style { styles[ref] = s }
                            }
                        }
                    }
                    row += rowRepeat
                case "table":
                    guard !inCell else { return }
                    var sheet = Sheet(id: sheets.count, name: name)
                    sheet.replaceAll(cells: cells, styles: styles)
                    sheets.append(sheet)
                default: break
                }
            },
            characters: { s in
                if inParagraph { paragraphs[paragraphs.count - 1] += s }
            })
        return Workbook(sheets: sheets)
    }

    /// The input string and implied style for one ODS cell.
    static func cellInput(type: String, value: String?, formula: String?, text: String) -> (String, CellStyle?) {
        if let formula, let converted = fromOpenFormula(formula) { return (converted, style(for: type)) }
        switch type {
        case "float", "percentage", "currency":
            return (value ?? text, style(for: type))
        case "boolean":
            return ((value ?? text).lowercased() == "true" ? "TRUE" : "FALSE", nil)
        case "date":
            let day = (value ?? "").prefix(10)
            if let serial = DateSerial.parseISO(String(day)) { return (CellValue.plainNumberText(serial), CellStyle(numberFormat: .date)) }
            return (XLSXReader.textInput(text), nil)
        default:
            return (XLSXReader.textInput(text), nil)
        }
    }

    private static func style(for type: String) -> CellStyle? {
        switch type {
        case "percentage": CellStyle(numberFormat: .percent)
        case "currency": CellStyle(numberFormat: .currency)
        case "date": CellStyle(numberFormat: .date)
        default: nil
        }
    }

    /// `of:=SUM([.A1:.B2];['My Sheet'.C3])` → `=SUM(A1:B2,'My Sheet'!C3)`.
    static func fromOpenFormula(_ f: String) -> String? {
        var s = Substring(f)
        if let colon = s.firstIndex(of: ":"), s[s.startIndex..<colon].allSatisfy({ $0.isLetter }) { s = s[s.index(after: colon)...] }
        guard s.hasPrefix("=") else { return nil }
        var out = ""
        var i = s.startIndex
        var inString = false
        while i < s.endIndex {
            let ch = s[i]
            if inString {
                out.append(ch)
                if ch == "\"" { inString = false }
                i = s.index(after: i)
                continue
            }
            switch ch {
            case "\"": inString = true; out.append(ch)
            case ";": out.append(",")
            case "[":
                guard let close = s[i...].firstIndex(of: "]") else { return nil }
                out += convertODFReference(String(s[s.index(after: i)..<close]))
                i = s.index(after: close)
                continue
            default: out.append(ch)
            }
            i = s.index(after: i)
        }
        return out
    }

    /// `.A1`, `Sheet1.A1`, `$'My Sheet'.$A$1:.B2` → A1 syntax.
    private static func convertODFReference(_ inner: String) -> String {
        let parts = inner.split(separator: ":", maxSplits: 1).map(String.init)
        var sheet: String?
        var points: [String] = []
        for p in parts {
            guard let dot = p.lastIndex(of: ".") else { points.append(p); continue }
            var name = String(p[p.startIndex..<dot])
            if name.hasPrefix("$") { name.removeFirst() }
            if name.hasPrefix("'") && name.hasSuffix("'") && name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            if !name.isEmpty, sheet == nil { sheet = name }
            points.append(String(p[p.index(after: dot)...]))
        }
        let prefix = sheet.map { Reference.quoteSheetName($0) + "!" } ?? ""
        return prefix + points.joined(separator: ":")
    }

    /// `=SUM(A1:B2,Sheet2!C3)` → `of:=SUM([.A1:.B2];[$Sheet2.C3])`.
    static func toOpenFormula(_ formula: String) -> String {
        guard formula.hasPrefix("=") else { return formula }
        var out = "of:="
        for t in Tokenizer.tokenize(String(formula.dropFirst())) {
            out += t.leading
            switch t.kind {
            case .comma: out += ";"
            case .reference(let r) where !r.isDeleted:
                let sheet = r.sheet.map { "$'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? ""
                out += "[" + sheet + "." + r.start.text
                if let e = r.end { out += ":" + (sheet.isEmpty ? "" : sheet) + "." + e.text }
                out += "]"
            default: out += t.text
            }
        }
        return out
    }

    // MARK: Writing

    public static func write(_ wb: Workbook, formulaValue: (Int, CellRef) -> CellValue?) throws -> Data {
        var x = XMLText.header
        x +=
            "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:of=\"urn:oasis:names:tc:opendocument:xmlns:of:1.2\" office:version=\"1.2\"><office:body><office:spreadsheet>"
        for sheet in wb.sheets {
            x += "<table:table table:name=\"\(XMLText.escape(sheet.name))\">"
            let cols = max(1, sheet.maxCol + 1)
            x += "<table:table-column table:number-columns-repeated=\"\(cols)\"/>"
            var byRow: [Int: [Int]] = [:]
            for ref in sheet.cells.keys { byRow[ref.row, default: []].append(ref.col) }
            var nextRow = 0
            for r in byRow.keys.sorted() {
                if r > nextRow {
                    x += "<table:table-row table:number-rows-repeated=\"\(r - nextRow)\"><table:table-cell/></table:table-row>"
                }
                x += "<table:table-row>"
                var nextCol = 0
                for c in (byRow[r] ?? []).sorted() {
                    if c > nextCol { x += "<table:table-cell table:number-columns-repeated=\"\(c - nextCol)\"/>" }
                    let ref = CellRef(row: r, col: c)
                    x += cellXML(sheet[ref], style: sheet.style(at: ref), cached: formulaValue(sheet.id, ref))
                    nextCol = c + 1
                }
                x += "</table:table-row>"
                nextRow = r + 1
            }
            if byRow.isEmpty { x += "<table:table-row><table:table-cell/></table:table-row>" }
            x += "</table:table>"
        }
        x += "</office:spreadsheet></office:body></office:document-content>"

        let manifest =
            XMLText.header + """
                <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">\
                <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>\
                <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\
                <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>\
                </manifest:manifest>
                """
        let styles =
            XMLText.header
            + "<office:document-styles xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" office:version=\"1.2\"/>"
        return try ZipPackage.write([
            ("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), true),
            ("META-INF/manifest.xml", Data(manifest.utf8), false),
            ("content.xml", Data(x.utf8), false),
            ("styles.xml", Data(styles.utf8), false),
        ])
    }

    private static func cellXML(_ input: String, style: CellStyle, cached: CellValue?) -> String {
        var attrs = ""
        let value: CellValue
        if input.hasPrefix("=") {
            attrs += " table:formula=\"\(XMLText.escape(toOpenFormula(input)))\""
            value = cached ?? .empty
        } else {
            value = CellValue.literal(input)
        }
        let shown = ValueFormatter.shared.string(for: value, format: style.numberFormat)
        switch value {
        case .number(let n):
            let text = CellValue.plainNumberText(n)
            switch style.numberFormat {
            case .date:
                if let c = DateSerial.components(n), c.day > 0 {
                    attrs += String(format: " office:value-type=\"date\" office:date-value=\"%04d-%02d-%02d\"", c.year, c.month, c.day)
                } else {
                    attrs += " office:value-type=\"float\" office:value=\"\(text)\""
                }
            case .percent: attrs += " office:value-type=\"percentage\" office:value=\"\(text)\""
            default: attrs += " office:value-type=\"float\" office:value=\"\(text)\""
            }
        case .bool(let b): attrs += " office:value-type=\"boolean\" office:boolean-value=\"\(b)\""
        case .text, .error: attrs += " office:value-type=\"string\""
        case .empty: return "<table:table-cell\(attrs)/>"
        }
        return "<table:table-cell\(attrs)><text:p>\(XMLText.escape(shown))</text:p></table:table-cell>"
    }
}
