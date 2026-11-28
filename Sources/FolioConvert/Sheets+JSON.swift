import FolioCode
import FolioSheets
import Foundation

/// JSON as a sheet: an array of flat objects (the keys are the header row) or an array of arrays.
///
/// A small parser of its own because `JSONSerialization` forgets key order, and the key
/// order is the column order.
nonisolated enum JSONSheet {
    indirect enum Value {
        case string(String), number(String), bool(Bool), null, array([Value]), object([(String, Value)])
    }

    // MARK: Writing

    /// An array of objects keyed by the first row. Blank or repeated keys get a column name.
    static func json(_ rows: [[CellValue]]) -> String {
        guard let header = rows.first else { return "[]" }
        let width = rows.map(\.count).max() ?? 0
        var keys: [String] = []
        for c in 0..<width {
            var key = c < header.count ? SheetConverter.display(header[c]) : ""
            if key.isEmpty { key = "column \(CellRef.columnName(c))" }
            var unique = key
            var n = 2
            while keys.contains(unique) {
                unique = "\(key) \(n)"
                n += 1
            }
            keys.append(unique)
        }
        let objects = rows.dropFirst().map { row in
            "{" + keys.indices.map { c in quote(keys[c]) + ":" + scalar(c < row.count ? row[c] : .empty) }.joined(separator: ",") + "}"
        }
        let minified = "[" + objects.joined(separator: ",") + "]"
        return ((try? JSONTools.format(minified)) ?? minified) + "\n"
    }

    static func scalar(_ value: CellValue) -> String {
        switch value {
        case .empty: "null"
        case .number(let n): CellValue.plainNumberText(n)
        case .bool(let b): b ? "true" : "false"
        case .text(let s): quote(s)
        case .error(let e): quote(e.rawValue)
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func text(_ value: Value) -> String {
        switch value {
        case .string(let s): quote(s)
        case .number(let n): n
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case .array(let a): "[" + a.map(text).joined(separator: ",") + "]"
        case .object(let o): "{" + o.map { quote($0.0) + ":" + text($0.1) }.joined(separator: ",") + "}"
        }
    }

    // MARK: Reading

    static func workbook(from data: Data) throws -> Workbook {
        var parser = Parser(bytes: Array(data))
        let root = try parser.document()
        guard case .array(let items) = root else {
            throw ConvertError(.corruptInput, "Folio reads JSON that is an array of objects or an array of arrays.")
        }
        var cells: [CellRef: String] = [:]
        if items.allSatisfy({ if case .object = $0 { true } else { false } }) {
            var columns: [String: Int] = [:]
            var order: [String] = []
            for case .object(let pairs) in items {
                for (key, _) in pairs where columns[key] == nil {
                    columns[key] = order.count
                    order.append(key)
                }
            }
            for (c, key) in order.enumerated() { cells[CellRef(row: 0, col: c)] = input(.string(key)) }
            for (r, item) in items.enumerated() {
                guard case .object(let pairs) = item else { continue }
                for (key, value) in pairs {
                    cells[CellRef(row: r + 1, col: columns[key]!)] = input(value)
                }
            }
        } else if items.allSatisfy({ if case .array = $0 { true } else { false } }) {
            for (r, item) in items.enumerated() {
                guard case .array(let values) = item else { continue }
                for (c, value) in values.enumerated() { cells[CellRef(row: r, col: c)] = input(value) }
            }
        } else {
            throw ConvertError(.corruptInput, "Folio reads JSON that is an array of objects or an array of arrays.")
        }
        cells = cells.filter { !$0.value.isEmpty }
        var sheet = Sheet(id: 0, name: "Sheet 1")
        sheet.replaceAll(cells: cells, styles: [:])
        return Workbook(sheets: [sheet])
    }

    /// The raw cell input that means exactly this JSON value. Strings that would read as a
    /// number, boolean, error or formula get the apostrophe that keeps them text.
    static func input(_ value: Value) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .number(let n): return n
        case .string(let s):
            if s.hasPrefix("=") || s.hasPrefix("'") || CellValue.literal(s) != .text(s) { return "'" + s }
            return s
        case .array, .object: return "'" + text(value)  // nested values are kept as their JSON text
        }
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            // Skip a UTF-8 byte order mark.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        }

        mutating func document() throws -> Value {
            let value = try parse()
            skip()
            guard i == bytes.count else { throw fail("unexpected text after the JSON value") }
            return value
        }

        func fail(_ message: String) -> ConvertError { ConvertError(.corruptInput, "This JSON can't be read at byte \(i): \(message).") }

        mutating func skip() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }

        mutating func parse() throws -> Value {
            skip()
            guard i < bytes.count else { throw fail("it ends too early") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var pairs: [(String, Value)] = []
                skip()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                while true {
                    skip()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                    let key = try string()
                    skip()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                    i += 1
                    pairs.append((key, try parse()))
                    skip()
                    guard i < bytes.count else { throw fail("an object isn't closed") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                    throw fail("expected ',' or '}'")
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [Value] = []
                skip()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    items.append(try parse())
                    skip()
                    guard i < bytes.count else { throw fail("an array isn't closed") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw fail("expected ',' or ']'")
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try word("true"); return .bool(true)
            case UInt8(ascii: "f"): try word("false"); return .bool(false)
            case UInt8(ascii: "n"): try word("null"); return .null
            default:
                let start = i
                while i < bytes.count, "+-.0123456789eE".utf8.contains(bytes[i]) { i += 1 }
                let raw = String(decoding: bytes[start..<i], as: UTF8.self)
                guard !raw.isEmpty, Double(raw) != nil else { throw fail("unexpected character") }
                return .number(raw)
            }
        }

        mutating func word(_ w: String) throws {
            let u = Array(w.utf8)
            guard bytes.count - i >= u.count, Array(bytes[i..<i + u.count]) == u else { throw fail("unexpected character") }
            i += u.count
        }

        mutating func string() throws -> String {
            i += 1  // opening quote
            var out: [UInt8] = []
            while i < bytes.count {
                let b = bytes[i]
                i += 1
                if b == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                guard b == UInt8(ascii: "\\") else { out.append(b); continue }
                guard i < bytes.count else { break }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), bytes.count - i >= 6, bytes[i] == UInt8(ascii: "\\"),
                        bytes[i + 1] == UInt8(ascii: "u")
                    {
                        i += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    out += Array(String(Unicode.Scalar(code).map(Character.init) ?? "\u{FFFD}").utf8)
                default: out.append(e)  // \" \\ \/
                }
            }
            throw fail("a string isn't closed")
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - i >= 4, let n = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
                throw fail("bad \\u escape")
            }
            i += 4
            return n
        }
    }
}
