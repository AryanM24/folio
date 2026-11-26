public import FolioKit
import Foundation
import UniformTypeIdentifiers

/// File tools owned by this module. Surfaced in the Welcome window, File > Tools and
/// Finder Quick Actions. See `FolioTool`.
public enum SpreadsheetTools {
    public nonisolated static let all: [FolioTool] = [convert, mergeCSV]

    private nonisolated static let spreadsheetTypes: [UTType] = SpreadsheetFormat.allCases.map(\.type)

    /// Converts each input to the chosen format, next to the original.
    nonisolated static let convert = FolioTool(
        id: "sheets.convert",
        title: "Convert Spreadsheets",
        subtitle: "Between Excel, OpenDocument, CSV and TSV",
        symbol: "arrow.triangle.2.circlepath",
        inputTypes: spreadsheetTypes,
        options: [
            .init(
                id: "format", label: "Convert to",
                choices: [
                    ("xlsx", "Excel (.xlsx)"), ("ods", "OpenDocument (.ods)"), ("csv", "CSV (.csv)"), ("tsv", "Tab-separated (.tsv)"),
                ], defaultValue: "xlsx")
        ]
    ) { inputs, options in
        guard let target = SpreadsheetFormat(rawValue: options["format"] ?? "xlsx") else {
            throw FolioError("Choose a format to convert to.")
        }
        return try inputs.map { url in try convertFile(url, to: target) }
    }

    /// Stacks CSV/TSV files into one, keeping a shared header row once.
    nonisolated static let mergeCSV = FolioTool(
        id: "sheets.mergeCSV",
        title: "Merge CSV Files",
        subtitle: "Combine rows from several CSV or TSV files",
        symbol: "square.stack.3d.down.right",
        inputTypes: [.commaSeparatedText, .tabSeparatedText],
        minimumInputs: 2
    ) { inputs, _ in
        let data = try mergeCSVFiles(inputs)
        guard let first = inputs.first else { return [] }
        let out = FolioTool.outputURL(nextTo: first, name: "Merged", ext: "csv")
        try data.write(to: out, options: .atomic)
        return [out]
    }

    nonisolated static func convertFile(_ url: URL, to target: SpreadsheetFormat) throws -> URL {
        guard let source = SpreadsheetFormat(fileExtension: url.pathExtension) else {
            throw FolioError("“\(url.lastPathComponent)” isn't a spreadsheet Folio can read.")
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw FolioError("Couldn't read “\(url.lastPathComponent)”.") }
        let wb = try source.read(data)
        let engine = FormulaEngine()
        engine.recalculateAll(wb)
        let out = FolioTool.outputURL(nextTo: url, name: url.deletingPathExtension().lastPathComponent, ext: target.fileExtension)
        try target.write(wb, values: engine.values).write(to: out, options: .atomic)
        return out
    }

    /// Rows of every file in order. When a file's first row equals the first file's
    /// header it's treated as a header and skipped.
    nonisolated static func mergeCSVFiles(_ urls: [URL]) throws -> Data {
        var rows: [[String]] = []
        var header: [String]?
        for url in urls {
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw FolioError("Couldn't read “\(url.lastPathComponent)”.") }
            let text = CSVCodec.decode(data)
            let delimiter =
                url.pathExtension.lowercased() == "tsv" ? UInt8(ascii: "\t") : CSVCodec.sniffDelimiter(Array(text.utf8.prefix(65536)))
            var fileRows = CSVCodec.rows(text, delimiter: delimiter)
            while fileRows.last?.allSatisfy(\.isEmpty) == true { fileRows.removeLast() }
            guard let first = fileRows.first else { continue }
            if let header {
                if first == header { fileRows.removeFirst() }
            } else {
                header = first
            }
            rows += fileRows
        }
        return Data(CSVCodec.write(rows: rows).utf8)
    }
}
