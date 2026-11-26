public import Foundation
import ZIPFoundation

/// Reads Office Open XML workbooks (.xlsx): sheets, shared and inline strings, numbers,
/// booleans, errors, formulas (including shared formulas), basic styles, column widths
/// and frozen panes. Charts, images, comments and conditional formats are ignored.
public nonisolated enum XLSXReader {
    public static func read(_ data: Data) throws(FolioSheetsError) -> Workbook {
        let archive = try ZipPackage.open(data)
        guard let workbookXML = try ZipPackage.read(archive, "xl/workbook.xml") else {
            throw .unreadableFile("This file doesn't contain a workbook.")
        }

        // workbook.xml: sheet names and relationship ids, active tab.
        var entries: [(name: String, rid: String)] = []
        var activeTab = 0
        try XMLScanner.scan(
            workbookXML,
            start: { name, a in
                if name == "sheet", let n = a["name"], let rid = a["r:id"] ?? a["id"] { entries.append((n, rid)) }
                if name == "workbookView", let t = a["activeTab"], let i = Int(t) { activeTab = i }
            })

        var targets: [String: String] = [:]
        if let rels = try ZipPackage.read(archive, "xl/_rels/workbook.xml.rels") {
            try XMLScanner.scan(
                rels,
                start: { name, a in
                    if name == "Relationship", let id = a["Id"], let t = a["Target"] { targets[id] = t }
                })
        }

        let strings = try sharedStrings(archive)
        let styles = try XLSXStyles.read(archive)

        var sheets: [Sheet] = []
        for (i, entry) in entries.enumerated() {
            var target = targets[entry.rid] ?? "worksheets/sheet\(i + 1).xml"
            target = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            var sheet = Sheet(id: i, name: entry.name)
            if let xml = try ZipPackage.read(archive, target) {
                readSheet(xml, into: &sheet, strings: strings, styles: styles)
            }
            sheets.append(sheet)
        }
        var wb = Workbook(sheets: sheets)
        wb.activeSheetIndex = min(max(0, activeTab), wb.sheets.count - 1)
        return wb
    }

    private static func sharedStrings(_ archive: Archive) throws(FolioSheetsError) -> [String] {
        guard let xml = try ZipPackage.read(archive, "xl/sharedStrings.xml") else { return [] }
        var out: [String] = []
        var current = ""
        var inPhonetic = false
        try XMLScanner.scan(
            xml,
            start: { name, _ in
                if name == "si" { current = "" }
                if name == "rPh" { inPhonetic = true }
            },
            end: { name, text in
                switch name {
                case "t": if !inPhonetic { current += text }
                case "rPh": inPhonetic = false
                case "si": out.append(current)
                default: break
                }
            })
        return out
    }

    private static func readSheet(_ xml: Data, into sheet: inout Sheet, strings: [String], styles: [CellStyle]) {
        let parsed = XLSXSheetParser(strings: strings, styles: styles).parse(xml)
        sheet.replaceAll(cells: parsed.cells, styles: parsed.styles)
        sheet.columnWidths = parsed.widths
        sheet.frozenRows = parsed.frozenRows
        sheet.frozenCols = parsed.frozenCols
    }

    /// Text that would otherwise be read as a number, boolean or formula keeps an
    /// apostrophe so "00123" stays text, as it was in the file.
    static func textInput(_ s: String) -> String {
        if s.isEmpty { return "" }
        if s.hasPrefix("=") || s.hasPrefix("'") { return "'" + s }
        if case .text = CellValue.literal(s) { return s }
        return "'" + s
    }
}

/// The subset of styles.xml we understand, flattened to one `CellStyle` per cellXfs entry.
nonisolated enum XLSXStyles {
    static func read(_ archive: Archive) throws(FolioSheetsError) -> [CellStyle] {
        guard let xml = try ZipPackage.read(archive, "xl/styles.xml") else { return [] }
        var numFmts: [Int: String] = [:]
        struct Font { var bold = false, italic = false, underline = false, color: RGBColor? }
        var fonts: [Font] = []
        var fills: [RGBColor?] = []
        var xfs: [CellStyle] = []
        var section = ""
        var font: Font?
        var fill: RGBColor?
        var fillIsSolid = false
        var xf: CellStyle?

        try XMLScanner.scan(
            xml,
            start: { name, a in
                switch name {
                case "numFmt": if let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"] { numFmts[id] = code }
                case "fonts", "fills", "cellXfs", "cellStyleXfs", "dxfs": section = name
                case "font": if section == "fonts" { font = Font() }
                case "b": if a["val"] != "0" && a["val"] != "false" { font?.bold = true }
                case "i": if a["val"] != "0" && a["val"] != "false" { font?.italic = true }
                case "u": if a["val"] != "none" { font?.underline = true }
                case "color": if section == "fonts", let rgb = a["rgb"].flatMap(RGBColor.init(hexString:)) { font?.color = rgb }
                case "fill": if section == "fills" { fill = nil; fillIsSolid = false }
                case "patternFill": fillIsSolid = a["patternType"] == "solid"
                case "fgColor": if section == "fills", fillIsSolid { fill = a["rgb"].flatMap(RGBColor.init(hexString:)) }
                case "xf":
                    guard section == "cellXfs" else { return }
                    var s = CellStyle()
                    let fid = a["fontId"].flatMap(Int.init) ?? 0
                    if fid < fonts.count {
                        s.bold = fonts[fid].bold
                        s.italic = fonts[fid].italic
                        s.underline = fonts[fid].underline
                        // Pure black is the default text color; don't store it as a choice.
                        if let c = fonts[fid].color, c.hex != 0 { s.textColor = c }
                    }
                    let fillID = a["fillId"].flatMap(Int.init) ?? 0
                    if fillID < fills.count { s.fill = fills[fillID] }
                    s.numberFormat = classify(a["numFmtId"].flatMap(Int.init) ?? 0, numFmts)
                    xf = s
                case "alignment":
                    if section == "cellXfs" {
                        switch a["horizontal"] {
                        case "left": xf?.alignment = .left
                        case "center", "centerContinuous": xf?.alignment = .center
                        case "right": xf?.alignment = .right
                        default: break
                        }
                    }
                default: break
                }
            },
            end: { name, _ in
                switch name {
                case "font": if section == "fonts", let f = font { fonts.append(f); font = nil }
                case "fill": if section == "fills" { fills.append(fill) }
                case "xf": if section == "cellXfs", let s = xf { xfs.append(s); xf = nil }
                case "fonts", "fills", "cellXfs", "cellStyleXfs", "dxfs": section = ""
                default: break
                }
            })
        return xfs
    }

    /// Maps a number format id/code onto Folio's five formats.
    static func classify(_ id: Int, _ custom: [Int: String]) -> NumberFormat {
        switch id {
        case 0: return .general
        case 1...4: return .number
        case 5...8, 37...44: return .currency
        case 9, 10: return .percent
        case 14...22, 45...47: return .date
        default: break
        }
        guard let code = custom[id] else { return .general }
        // Strip quoted literals and [color]/[locale] blocks before looking for tokens.
        var plain = ""
        var inQuote = false, inBracket = false
        for ch in code {
            if ch == "\"" { inQuote.toggle(); continue }
            if ch == "[" { inBracket = true; continue }
            if ch == "]" { inBracket = false; continue }
            if !inQuote && !inBracket { plain.append(ch) }
        }
        let lower = plain.lowercased()
        if lower.contains("%") { return .percent }
        if lower.contains("y") || lower.contains("d") || (lower.contains("m") && !lower.contains("0")) { return .date }
        if code.contains("$") || code.contains("€") || code.contains("£") || code.contains("¥") { return .currency }
        if lower.contains("0") || lower.contains("#") { return .number }
        return .general
    }
}
