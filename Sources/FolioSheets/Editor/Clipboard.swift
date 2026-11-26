import AppKit

/// Clipboard representations of a block of cells.
///
/// Three flavours go on the pasteboard so pastes work everywhere:
/// - Folio's own type (JSON `CellBlock`) keeps formulas and styles, and lets relative
///   references shift on paste;
/// - TSV text, which Numbers, Excel and Google Sheets all read as cells;
/// - an HTML table, which keeps bold/italic and colours in rich-text apps.
nonisolated enum ClipboardFormat {
    static let cellsType = NSPasteboard.PasteboardType("app.folio.sheets.cells")

    /// Tab-separated displayed values; fields with tabs, quotes or newlines are quoted.
    static func tsv(rows: [[String]]) -> String {
        rows.map { row in
            row.map { field in
                field.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" })
                    ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    : field
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func html(rows: [[String]], styles: [[CellStyle]]) -> String {
        var h = "<meta charset=\"utf-8\"><table>"
        for (r, row) in rows.enumerated() {
            h += "<tr>"
            for (c, text) in row.enumerated() {
                let s = styles[r][c]
                var css: [String] = []
                if s.bold { css.append("font-weight:bold") }
                if s.italic { css.append("font-style:italic") }
                if s.underline { css.append("text-decoration:underline") }
                if let f = s.fill { css.append("background-color:#\(f.hexString)") }
                if let t = s.textColor { css.append("color:#\(t.hexString)") }
                if s.alignment != .automatic { css.append("text-align:\(s.alignment.rawValue)") }
                let style = css.isEmpty ? "" : " style=\"\(css.joined(separator: ";"))\""
                h += "<td\(style)>" + XMLText.escape(text).replacingOccurrences(of: "\n", with: "<br>") + "</td>"
            }
            h += "</tr>"
        }
        return h + "</table>"
    }

    /// Parses pasted text into a block. Tabs win; otherwise the CSV sniffer decides.
    static func block(fromText text: String, at origin: CellRef) -> CellBlock {
        let delimiter = text.contains("\t") ? UInt8(ascii: "\t") : CSVCodec.sniffDelimiter(Array(text.utf8.prefix(65536)))
        var rows = CSVCodec.rows(text, delimiter: text.contains("\n") || text.contains("\t") ? delimiter : UInt8(ascii: "\t"))
        while rows.count > 1, rows.last?.allSatisfy(\.isEmpty) == true { rows.removeLast() }
        let cols = max(1, rows.map(\.count).max() ?? 1)
        if rows.isEmpty { rows = [[""]] }
        var contents: [CellContent] = []
        for row in rows {
            for c in 0..<cols { contents.append(CellContent(input: c < row.count ? row[c] : "")) }
        }
        return CellBlock(origin: origin, rows: rows.count, cols: cols, contents: contents)
    }
}

extension SheetController {
    func copy() {
        let range = clipboardRange
        let s = sheet
        let block = CellBlock(sheet: s, range: range)
        var texts: [[String]] = [], styles: [[CellStyle]] = []
        for r in range.rows {
            texts.append(range.cols.map { document.displayText(at: CellRef(row: r, col: $0)) })
            styles.append(range.cols.map { s.style(at: CellRef(row: r, col: $0)) })
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(ClipboardFormat.tsv(rows: texts), forType: .string)
        pb.setString(ClipboardFormat.html(rows: texts, styles: styles), forType: .html)
        if let data = try? JSONEncoder().encode(block) { pb.setData(data, forType: ClipboardFormat.cellsType) }
    }

    /// Copies, then clears the source (the clipboard keeps formulas and styles).
    func cut() {
        copy()
        document.apply(RangeEdits.clear(clipboardRange, in: sheet, styles: true), actionName: "Cut", undoManager: undoManager)
    }

    func paste() {
        let pb = NSPasteboard.general
        let target = selectedRange
        let block: CellBlock
        if let data = pb.data(forType: ClipboardFormat.cellsType), let b = try? JSONDecoder().decode(CellBlock.self, from: data) {
            block = b
        } else if let text = pb.string(forType: .string) {
            block = ClipboardFormat.block(fromText: text, at: target.start)
        } else {
            NSSound.beep()
            return
        }
        let fill = block.rows * block.cols == 1 && !target.isSingleCell && target.cellCount <= 100_000 ? target : nil
        let changes = RangeEdits.paste(block, at: target.start, fillRange: fill)
        document.apply(changes, actionName: "Paste", undoManager: undoManager)
        var s = Selection(target.start)
        s.cursor = target.start.offset(rows: max(block.rows, fill?.rowCount ?? 0) - 1, cols: max(block.cols, fill?.colCount ?? 0) - 1)
        selection = s
    }

    /// Whole-column copies are limited to the rows that hold data.
    private var clipboardRange: CellRange {
        let r = effectiveRange
        guard r.cellCount > 1_000_000 else { return r }
        return CellRange(r.start, CellRef(row: r.start.row + 1_000_000 / max(1, r.colCount) - 1, col: r.end.col))
    }
}
