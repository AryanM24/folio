import FolioCode
import FolioSheets
public import Foundation

/// Sheets conversions, built on Folio's spreadsheet codecs.
///
/// Formulas are recalculated once per job, so value-only outputs (CSV, TSV, JSON, HTML,
/// Markdown) carry what the formulas compute, never the formula text.
public nonisolated enum SheetConverter: FamilyConverter {
    public static let family: Format.Family = .spreadsheet

    static let sources: [Format] = [.xlsx, .ods, .csv, .tsv, .json]
    static let outputs: [Format] = [.xlsx, .ods, .csv, .tsv, .json, .html, .md]
    /// Rows per sheet `extract` returns, so an agent's context isn't flooded.
    static let extractRowLimit = 2000

    public static func targets(from source: Format) -> [Target] {
        guard sources.contains(source) else { return [] }
        let workbook = source == .xlsx || source == .ods
        return outputs.filter { $0 != source }.map { target in
            switch target {
            case .xlsx, .ods:
                return Target(
                    to: target, fidelity: .lossless, losslessAvailable: true, drops: workbook ? ["charts", "images", "comments"] : [],
                    notes: workbook ? "Values, formulas and basic cell styles." : nil)
            case .csv, .tsv,
                .json where workbook:
                return Target(
                    to: target, fidelity: .contentOnly, losslessAvailable: false, drops: ["formulas", "formatting"],
                    notes: "Formulas are written as their values. A workbook with several sheets becomes a folder with one file per sheet.")
            case .csv,
                .tsv where source != .json:
                return Target(to: target, fidelity: .lossless, losslessAvailable: true, notes: "Formulas are written as their values.")
            case .json:
                return Target(to: target, fidelity: .contentOnly, losslessAvailable: false, notes: "The first row becomes the keys.")
            case .csv, .tsv:
                return Target(
                    to: target, fidelity: .contentOnly, losslessAvailable: false, notes: "Numbers and text are no longer told apart.")
            default:
                return Target(
                    to: target, fidelity: .contentOnly, losslessAvailable: false, drops: workbook ? ["formulas", "formatting"] : [])
            }
        }
    }

    public static func convert(_ job: Job) async throws -> Outcome {
        let pair = targets(from: job.source).first { $0.to == job.target }
        let wb = try read(job.input, as: job.source)
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        job.progress(0.4)

        var isDirectory = false
        var dropped = pair?.drops ?? []
        switch job.target {
        case .xlsx, .ods:
            try spreadsheetFormat(job.target).write(wb, values: engine.values).write(to: job.output)
        case .csv, .tsv, .json:
            if wb.sheets.count > 1 {
                // One file per sheet, so nothing is left behind.
                isDirectory = true
                try FileManager.default.createDirectory(at: job.output, withIntermediateDirectories: false)
                for (sheet, url) in zip(wb.sheets, sheetFiles(wb, in: job.output, as: job.target)) {
                    try valueData(sheet, engine: engine, as: job.target).write(to: url)
                }
            } else {
                try valueData(wb.sheets[0], engine: engine, as: job.target).write(to: job.output)
            }
            // Say only what this file actually had.
            dropped = []
            if wb.sheets.contains(where: { $0.cells.values.contains { $0.hasPrefix("=") } }) { dropped.append("formulas") }
            if wb.sheets.contains(where: { !$0.styles.isEmpty }) { dropped.append("formatting") }
        case .html:
            try Data(html(wb, engine: engine, title: job.input.deletingPathExtension().lastPathComponent).utf8).write(to: job.output)
        case .md:
            try Data(markdown(wb, engine: engine, rowLimit: nil).utf8).write(to: job.output)
        default:
            throw ConvertError(.unsupportedPair, "Folio can't write spreadsheets as \(job.target.title).")
        }
        job.progress(0.8)

        var verification: Verification?
        if job.verify {
            verification = try verify(wb, engine: engine, output: job.output, as: job.target, isDirectory: isDirectory)
        }
        let cells = wb.sheets.reduce(0) { $0 + $1.cells.count }
        return Outcome(
            fidelity: pair?.fidelity ?? .contentOnly, method: "convert",
            details: ["sheets": .int(Int64(wb.sheets.count)), "cells": .int(Int64(cells))], dropped: dropped,
            verification: verification, isDirectory: isDirectory)
    }

    public static func inspect(_ url: URL, format: Format) async throws -> [String: JSONValue] {
        let wb = try read(url, as: format)
        let sheets: [JSONValue] = wb.sheets.map { sheet in
            .object([
                "name": .string(sheet.name), "rows": .int(Int64(sheet.usedRange.map { $0.end.row + 1 } ?? 0)),
                "cols": .int(Int64(sheet.usedRange.map { $0.end.col + 1 } ?? 0)),
            ])
        }
        return ["sheets": .array(sheets), "has_formulas": .bool(wb.sheets.contains { $0.cells.values.contains { $0.hasPrefix("=") } })]
    }

    public static func extract(_ url: URL, format: Format, as kind: ExtractKind, options: ExtractOptions) async throws -> String {
        var wb = try read(url, as: format)
        if let name = options.sheet {
            guard let index = wb.index(ofSheetNamed: name) else {
                throw ConvertError(
                    .unsupportedInput, "There's no sheet called “\(name)”.",
                    hint: "Sheets: \(wb.sheets.map(\.name).joined(separator: ", ")).")
            }
            wb.sheets = [wb.sheets[index]]
        }
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        if kind == .markdown { return markdown(wb, engine: engine, rowLimit: extractRowLimit) }
        return wb.sheets.map { sheet in
            let rows = valueRows(sheet, engine: engine)
            var text = rows.prefix(extractRowLimit).map {
                $0.map { display($0).replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t")
            }
            .joined(separator: "\n")
            if rows.count > extractRowLimit { text += "\n[\(rows.count - extractRowLimit) more rows not shown]" }
            return wb.sheets.count > 1 ? "# \(sheet.name)\n\(text)" : text
        }.joined(separator: "\n\n")
    }

    public static func resource(for job: Job) -> Resource { .cpu }

    // MARK: Reading

    static func read(_ url: URL, as format: Format) throws -> Workbook {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw ConvertError(.notFound, "Couldn't read \(url.lastPathComponent).")
        }
        do {
            if format == .json { return try JSONSheet.workbook(from: data) }
            return try spreadsheetFormat(format).read(data)
        } catch let error as ConvertError {
            throw error
        } catch {
            throw ConvertError(.corruptInput, "This isn't a readable \(format.title) file: \(error.localizedDescription)")
        }
    }

    static func spreadsheetFormat(_ format: Format) throws -> SpreadsheetFormat {
        guard let f = SpreadsheetFormat(fileExtension: format.fileExtension) else {
            throw ConvertError(.unsupportedPair, "Folio can't read or write \(format.title) as a spreadsheet codec.")
        }
        return f
    }

    // MARK: Values

    /// What a cell holds once formulas are evaluated.
    static func value(_ sheet: Sheet, _ ref: CellRef, engine: FormulaEngine) -> CellValue {
        let input = sheet[ref]
        if input.hasPrefix("=") { return engine.value(sheetID: sheet.id, cell: ref) ?? .empty }
        return CellValue.literal(input)
    }

    /// Text for value-only formats: typed input as is ("00123", "1,234"), formulas as their result.
    static func text(_ sheet: Sheet, _ ref: CellRef, engine: FormulaEngine) -> String {
        let input = sheet[ref]
        if input.hasPrefix("=") { return display(engine.value(sheetID: sheet.id, cell: ref) ?? .empty) }
        return input.hasPrefix("'") ? String(input.dropFirst()) : input
    }

    static func display(_ value: CellValue) -> String {
        switch value {
        case .empty: ""
        case .number(let n): CellValue.plainNumberText(n)
        case .text(let s): s
        case .bool(let b): b ? "TRUE" : "FALSE"
        case .error(let e): e.rawValue
        }
    }

    /// Non-empty rows in order, each as wide as its last used cell.
    static func valueRows(_ sheet: Sheet, engine: FormulaEngine) -> [[CellValue]] {
        var byRow: [Int: Int] = [:]
        for ref in sheet.cells.keys { byRow[ref.row] = max(byRow[ref.row] ?? 0, ref.col) }
        return byRow.keys.sorted().map { row in
            (0...byRow[row]!).map { value(sheet, CellRef(row: row, col: $0), engine: engine) }
        }
    }

    static func valueData(_ sheet: Sheet, engine: FormulaEngine, as format: Format) throws -> Data {
        switch format {
        case .csv, .tsv:
            return CSVCodec.write(sheet, values: { text(sheet, $0, engine: engine) }, delimiter: format == .tsv ? "\t" : ",")
        case .json:
            return Data(JSONSheet.json(valueRows(sheet, engine: engine)).utf8)
        default:
            throw ConvertError(.unsupportedPair, "\(format.title) isn't a value-only format.")
        }
    }

    /// One file per sheet, named after it: no path separators or colons, unique ignoring case.
    static func sheetFiles(_ wb: Workbook, in folder: URL, as format: Format) -> [URL] {
        var used: Set<String> = []
        return wb.sheets.map { sheet in
            var base = sheet.name.map { "/:\\".contains($0) ? "-" : String($0) }.joined().trimmingCharacters(in: .whitespaces)
            if base.isEmpty || base.hasPrefix(".") { base = "Sheet" + base }
            var name = base
            var n = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(n)"
                n += 1
            }
            used.insert(name.lowercased())
            return folder.appending(path: "\(name).\(format.fileExtension)")
        }
    }

    // MARK: HTML and Markdown

    static func html(_ wb: Workbook, engine: FormulaEngine, title: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(
                of: ">", with: "&gt;"
            )
            .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var out = """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><title>\(esc(title))</title>
            <style>body{font:14px -apple-system,sans-serif;margin:2em}table{border-collapse:collapse;margin-bottom:2em}td,th{border:1px solid #ccc;padding:4px 8px}th{background:#f4f4f4;text-align:left}td.n{text-align:right}</style>
            </head><body>

            """
        for sheet in wb.sheets {
            let rows = valueRows(sheet, engine: engine)
            let width = rows.map(\.count).max() ?? 0
            if wb.sheets.count > 1 { out += "<h2>\(esc(sheet.name))</h2>\n" }
            out += "<table>\n"
            for (i, row) in rows.enumerated() {
                let cells = (0..<width).map { c -> String in
                    let v = c < row.count ? row[c] : .empty
                    let tag = i == 0 ? "th" : "td"
                    return "<\(tag)\(v.isNumber && i > 0 ? " class=\"n\"" : "")>\(esc(display(v)))</\(tag)>"
                }
                out += "<tr>" + cells.joined() + "</tr>\n"
            }
            out += "</table>\n"
        }
        return out + "</body></html>\n"
    }

    /// One Markdown table per sheet; the first row is the header.
    static func markdown(_ wb: Workbook, engine: FormulaEngine, rowLimit: Int?) -> String {
        func cell(_ v: CellValue) -> String {
            display(v).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        return wb.sheets.map { sheet in
            var rows = valueRows(sheet, engine: engine)
            let heading = wb.sheets.count > 1 ? "## \(sheet.name)\n\n" : ""
            guard !rows.isEmpty else { return heading + "_Empty sheet._\n" }
            var note = ""
            if let limit = rowLimit, rows.count > limit + 1 {
                note = "\n_\(rows.count - limit - 1) more rows not shown._\n"
                rows = Array(rows.prefix(limit + 1))
            }
            let width = rows.map(\.count).max() ?? 1
            func line(_ row: [CellValue]) -> String {
                "| " + (0..<width).map { $0 < row.count ? cell(row[$0]) : "" }.joined(separator: " | ") + " |"
            }
            let separator = "|" + String(repeating: " --- |", count: width)
            return heading + ([line(rows[0]), separator] + rows.dropFirst().map(line)).joined(separator: "\n") + "\n" + note
        }.joined(separator: "\n")
    }

    // MARK: Verification

    /// Re-reads what was written and compares every value (and formula, for workbooks).
    static func verify(_ wb: Workbook, engine: FormulaEngine, output: URL, as format: Format, isDirectory: Bool) throws -> Verification? {
        switch format {
        case .xlsx, .ods:
            let back = try spreadsheetFormat(format).read(try Data(contentsOf: output))
            let backEngine = FormulaEngine()
            backEngine.recalculateAll(back)
            guard back.sheets.count == wb.sheets.count else {
                return Verification(passed: false, checks: ["opens", "sheet count differs"])
            }
            var differing = 0, formulas = 0
            for (a, b) in zip(wb.sheets, back.sheets) {
                for ref in Set(a.cells.keys).union(b.cells.keys) {
                    if a[ref].hasPrefix("=") || b[ref].hasPrefix("=") {
                        formulas += 1
                        if a[ref] != b[ref] { differing += 1; continue }
                    }
                    if display(value(a, ref, engine: engine)) != display(value(b, ref, engine: backEngine)) { differing += 1 }
                }
            }
            return Verification(
                passed: differing == 0, checks: ["opens", differing == 0 ? "values and formulas identical" : "cells differ"],
                metrics: ["differing_cells": Double(differing), "formulas": Double(formulas)])
        case .csv, .tsv, .json:
            var differing = 0
            let urls = isDirectory ? sheetFiles(wb, in: output, as: format) : [output]
            for (sheet, url) in zip(wb.sheets, urls) {
                let back = try read(url, as: format).sheets[0]
                let backEngine = FormulaEngine()
                let expected = valueRows(sheet, engine: engine).map { trimmed($0.map(display)) }
                let actual = valueRows(back, engine: backEngine).map { trimmed($0.map(display)) }
                differing += zip(expected, actual).count { $0 != $1 } + abs(expected.count - actual.count)
            }
            return Verification(
                passed: differing == 0, checks: ["opens", differing == 0 ? "values identical" : "values differ"],
                metrics: ["differing_rows": Double(differing)])
        default:
            return nil
        }
    }

    static func trimmed(_ row: [String]) -> [String] {
        var row = row
        while row.last?.isEmpty == true { row.removeLast() }
        return row
    }
}
