public import Foundation

/// RFC 4180 CSV and TSV, with delimiter sniffing and text-encoding detection.
///
/// The parser works on UTF-8 bytes in one pass so a 100k-row file opens in well under
/// a second; fields are only turned into `String`s once their bounds are known.
public nonisolated enum CSVCodec {
    // MARK: Reading

    /// Parse CSV/TSV bytes into a one-sheet workbook. `delimiter` nil means sniff.
    public static func read(_ data: Data, delimiter: UInt8? = nil, sheetName: String = "Sheet 1") -> Workbook {
        let text = decode(data)
        var utf8 = Array(text.utf8)
        let delim = delimiter ?? sniffDelimiter(utf8)
        var cells: [CellRef: String] = [:]
        cells.reserveCapacity(utf8.count / 8)
        parse(&utf8, delimiter: delim) { row, col, field in
            if !field.isEmpty { cells[CellRef(row: row, col: col)] = field }
        }
        var sheet = Sheet(id: 0, name: sheetName)
        sheet.replaceAll(cells: cells, styles: [:])
        return Workbook(sheets: [sheet])
    }

    /// Parse into rows of fields (used by paste and the merge tool).
    public static func rows(_ text: String, delimiter: UInt8) -> [[String]] {
        var utf8 = Array(text.utf8)
        var out: [[String]] = []
        parse(&utf8, delimiter: delimiter) { row, col, field in
            while out.count <= row { out.append([]) }
            while out[row].count < col { out[row].append("") }
            out[row].append(field)
        }
        return out
    }

    /// Single-pass state machine over bytes. Quoted fields may contain delimiters,
    /// doubled quotes and newlines. Accepts LF, CRLF and lone CR line endings.
    static func parse(_ bytes: inout [UInt8], delimiter: UInt8, emit: (Int, Int, String) -> Void) {
        let quote = UInt8(ascii: "\""), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var row = 0, col = 0, i = 0
        let n = bytes.count
        var field: [UInt8] = []
        bytes.withUnsafeBufferPointer { buf in
            func flush(_ slice: UnsafeBufferPointer<UInt8>.SubSequence) {
                emit(row, col, String(decoding: slice, as: UTF8.self))
            }
            while i < n {
                if buf[i] == quote {
                    // Quoted field.
                    i += 1
                    field.removeAll(keepingCapacity: true)
                    while i < n {
                        if buf[i] == quote {
                            if i + 1 < n && buf[i + 1] == quote { field.append(quote); i += 2; continue }
                            i += 1
                            break
                        }
                        field.append(buf[i])
                        i += 1
                    }
                    // Tolerate junk between the closing quote and the delimiter.
                    while i < n, buf[i] != delimiter, buf[i] != lf, buf[i] != cr { field.append(buf[i]); i += 1 }
                    emit(row, col, String(decoding: field, as: UTF8.self))
                } else {
                    let start = i
                    while i < n, buf[i] != delimiter, buf[i] != lf, buf[i] != cr { i += 1 }
                    if i > start { flush(buf[start..<i]) }
                }
                guard i < n else { break }
                if buf[i] == delimiter {
                    col += 1
                    i += 1
                } else {
                    // Line break (CRLF counts once).
                    if buf[i] == cr, i + 1 < n, buf[i + 1] == lf { i += 1 }
                    i += 1
                    row += 1
                    col = 0
                }
            }
        }
    }

    /// Picks the delimiter that splits the first lines most consistently.
    static func sniffDelimiter(_ bytes: [UInt8]) -> UInt8 {
        let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: "\t"), UInt8(ascii: ";"), UInt8(ascii: "|")]
        var lines: [[UInt8: Int]] = [[:]]
        var inQuotes = false
        for b in bytes.prefix(64 * 1024) {
            if b == UInt8(ascii: "\"") { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if b == UInt8(ascii: "\n") {
                if lines.count >= 20 { break }
                lines.append([:])
                continue
            }
            if candidates.contains(b) { lines[lines.count - 1][b, default: 0] += 1 }
        }
        lines = lines.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return UInt8(ascii: ",") }
        var best = UInt8(ascii: ","), bestScore = -1
        for c in candidates {
            let counts = lines.map { $0[c] ?? 0 }
            guard let first = counts.first, first > 0 else { continue }
            // Lines that agree with the first line's count, weighted by how many fields that gives.
            let agreeing = counts.filter { $0 == first }.count
            let score = agreeing * 1000 + first
            if score > bestScore { bestScore = score; best = c }
        }
        return best
    }

    /// BOMs first, then strict UTF-8, then UTF-16 heuristics, then Windows-1252
    /// (what Excel on Windows writes) as the fallback that never fails.
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        // UTF-16 without BOM: every other byte is zero in mostly-ASCII text. Checked before
        // UTF-8 because NUL bytes are technically valid UTF-8.
        let sample = [UInt8](data.prefix(512))
        if sample.count >= 4 {
            let evens = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let odds = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let half = sample.count / 2
            if odds > half * 3 / 4, let s = String(data: data, encoding: .utf16LittleEndian) { return s }
            if evens > half * 3 / 4, let s = String(data: data, encoding: .utf16BigEndian) { return s }
        }
        if let s = String(validating: data, as: UTF8.self) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Writing

    /// Writes one sheet's *values* (formulas can't live in CSV). UTF-8, CRLF line
    /// endings per RFC 4180; fields are quoted only when they need to be.
    public static func write(_ sheet: Sheet, values: (CellRef) -> String, delimiter: Character = ",") -> Data {
        guard let used = sheet.usedRange else { return Data() }
        // Group cells by row so empty rows cost nothing.
        var byRow: [Int: [Int]] = [:]
        for ref in sheet.cells.keys { byRow[ref.row, default: []].append(ref.col) }
        var out = ""
        out.reserveCapacity(sheet.cells.count * 8)
        for r in 0...used.end.row {
            if let cols = byRow[r], let last = cols.max() {
                for c in 0...last {
                    if c > 0 { out.append(delimiter) }
                    out += escape(values(CellRef(row: r, col: c)), delimiter: delimiter)
                }
            }
            out += "\r\n"
        }
        // Trailing empty lines carry no data.
        while out.hasSuffix("\r\n\r\n") { out.removeLast(2) }
        return Data(out.utf8)
    }

    /// Writes rows of fields (merge tool, clipboard).
    public static func write(rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { $0.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter)) }.joined(separator: "\r\n")
    }

    static func escape(_ field: String, delimiter: Character) -> String {
        guard
            field.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || field.hasPrefix(" ")
                || field.hasSuffix(" ")
        else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
