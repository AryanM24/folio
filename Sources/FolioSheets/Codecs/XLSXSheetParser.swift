import Foundation

/// A byte-level reader for worksheet XML (`xl/worksheets/sheetN.xml`).
///
/// Worksheets are by far the largest part of an .xlsx (a 100k × 50 sheet is ~250 MB of
/// XML). `XMLParser` builds an attribute dictionary and Strings for every element and
/// took ~10 s for such a sheet; this scanner looks only at the handful of elements we
/// need (`row`, `c`, `v`, `f`, `t`, `col`, `pane`) and works on raw bytes, about 8× faster.
/// It handles namespace prefixes, entities, numeric character references and CDATA.
nonisolated struct XLSXSheetParser {
    struct Output {
        var cells: [CellRef: String] = [:]
        var styles: [CellRef: CellStyle] = [:]
        var widths: [Int: Double] = [:]
        var frozenRows = 0
        var frozenCols = 0
    }

    let strings: [String]
    let styles: [CellStyle]

    func parse(_ data: Data) -> Output {
        data.withUnsafeBytes { raw in
            parse(raw.bindMemory(to: UInt8.self))
        }
    }

    private enum Tag { case row, c, v, f, t, col, pane, other }

    private func parse(_ b: UnsafeBufferPointer<UInt8>) -> Output {
        var out = Output()
        out.cells.reserveCapacity(b.count / 40)
        let n = b.count
        var i = 0

        // Current cell.
        var ref: CellRef?
        var typeBytes: ArraySlice<UInt8> = []
        var styleIndex = 0
        var value: String?
        var formula: String?
        var inline = ""
        var sharedIndex: String?
        var sharedMasters: [String: (CellRef, String)] = [:]
        var nextRow = 0, nextCol = 0
        var textStart = -1
        var textTag: Tag = .other
        var inCell = false

        func finishCell() {
            inCell = false
            guard let at = ref else { return }
            nextCol = at.col + 1
            if styleIndex > 0, styleIndex < styles.count, !styles[styleIndex].isPlain { out.styles[at] = styles[styleIndex] }
            let input: String
            if let formula, !formula.isEmpty {
                input = "=" + formula
            } else {
                switch String(decoding: typeBytes, as: UTF8.self) {
                case "s":
                    input =
                        value.flatMap(Int.init).flatMap { $0 >= 0 && $0 < strings.count ? strings[$0] : nil }.map(XLSXReader.textInput)
                        ?? ""
                case "inlineStr": input = XLSXReader.textInput(inline)
                case "str": input = XLSXReader.textInput(value ?? "")
                case "b": input = value == "1" ? "TRUE" : "FALSE"
                case "e": input = value ?? "#N/A"
                default: input = value ?? ""
                }
            }
            if !input.isEmpty { out.cells[at] = input }
            ref = nil
        }

        while i < n {
            // Jump to the next tag.
            guard let lt = Self.find(UInt8(ascii: "<"), in: b, from: i) else { break }
            i = lt + 1
            guard i < n else { break }
            switch b[i] {
            case UInt8(ascii: "/"):
                let nameStart = i + 1
                var j = nameStart
                while j < n, b[j] != UInt8(ascii: ">") { j += 1 }
                let tag = Self.tag(b, nameStart, j)
                if textStart >= 0, tag == textTag {
                    let text = Self.decode(b, textStart, lt)
                    switch tag {
                    case .v: value = text
                    case .t: if inCell { inline += text }
                    case .f: formula = text
                    default: break
                    }
                    textStart = -1
                }
                if tag == .f, inCell, let r = ref {
                    if let f = formula, !f.isEmpty {
                        if let si = sharedIndex { sharedMasters[si] = (r, f) }
                    } else if let si = sharedIndex, let (origin, master) = sharedMasters[si] {
                        formula = String(
                            ReferenceRewriter.offset("=" + master, rows: r.row - origin.row, cols: r.col - origin.col).dropFirst())
                    }
                }
                if tag == .c { finishCell() }
                i = j + 1
            case UInt8(ascii: "?"), UInt8(ascii: "!"):
                // CDATA carries text; comments and declarations are skipped.
                if Self.hasPrefix(b, i, "![CDATA["), let end = Self.find("]]>", in: b, from: i) {
                    if textStart >= 0 {
                        let before = Self.decode(b, textStart, lt)
                        let cdata = String(decoding: UnsafeBufferPointer(rebasing: b[(i + 8)..<end]), as: UTF8.self)
                        switch textTag {
                        case .v: value = before + cdata
                        case .t: if inCell { inline += before + cdata }
                        case .f: formula = before + cdata
                        default: break
                        }
                        textStart = -1
                    }
                    i = end + 3
                } else {
                    while i < n, b[i] != UInt8(ascii: ">") { i += 1 }
                    i += 1
                }
            default:
                let nameStart = i
                var j = i
                while j < n, b[j] != UInt8(ascii: " "), b[j] != UInt8(ascii: ">"), b[j] != UInt8(ascii: "/"), b[j] != 9, b[j] != 10,
                    b[j] != 13
                { j += 1 }
                let tag = Self.tag(b, nameStart, j)
                // Find the end of the tag, honouring quotes.
                var k = j
                var quote: UInt8 = 0
                while k < n {
                    let ch = b[k]
                    if quote != 0 {
                        if ch == quote { quote = 0 }
                    } else if ch == UInt8(ascii: "\"") || ch == UInt8(ascii: "'") {
                        quote = ch
                    } else if ch == UInt8(ascii: ">") {
                        break
                    }
                    k += 1
                }
                let selfClosing = k > 0 && b[k - 1] == UInt8(ascii: "/")
                let attrs = j..<k
                switch tag {
                case .row:
                    if let r = Self.attr(b, attrs, "r").flatMap({ Int(Self.string(b, $0)) }) { nextRow = r - 1 }
                    nextCol = 0
                case .c:
                    inCell = true
                    ref = Self.attr(b, attrs, "r").flatMap { Self.cellRef(b, $0) } ?? CellRef(row: nextRow, col: nextCol)
                    typeBytes = Self.attr(b, attrs, "t").map { Array(b[$0])[...] } ?? []
                    styleIndex = Self.attr(b, attrs, "s").flatMap { Int(Self.string(b, $0)) } ?? 0
                    value = nil
                    formula = nil
                    inline = ""
                    sharedIndex = nil
                    if selfClosing { finishCell() }
                case .f:
                    if Self.attr(b, attrs, "t").map({ Self.string(b, $0) }) == "shared" {
                        sharedIndex = Self.attr(b, attrs, "si").map { Self.string(b, $0) }
                    }
                    if selfClosing, inCell, let r = ref, let si = sharedIndex, let (origin, master) = sharedMasters[si] {
                        formula = String(
                            ReferenceRewriter.offset("=" + master, rows: r.row - origin.row, cols: r.col - origin.col).dropFirst())
                    }
                case .col:
                    if let mn = Self.attr(b, attrs, "min").flatMap({ Int(Self.string(b, $0)) }),
                        let mx = Self.attr(b, attrs, "max").flatMap({ Int(Self.string(b, $0)) }),
                        let w = Self.attr(b, attrs, "width").flatMap({ Double(Self.string(b, $0)) }),
                        mn >= 1, mx >= mn, mx - mn < 16384
                    {
                        for c in mn...mx { out.widths[c - 1] = (w * 7 + 5).rounded() }
                    }
                case .pane:
                    let state = Self.attr(b, attrs, "state").map { Self.string(b, $0) }
                    if state == "frozen" || state == "frozenSplit" {
                        out.frozenCols = Self.attr(b, attrs, "xSplit").flatMap { Double(Self.string(b, $0)) }.map { Int($0) } ?? 0
                        out.frozenRows = Self.attr(b, attrs, "ySplit").flatMap { Double(Self.string(b, $0)) }.map { Int($0) } ?? 0
                    }
                default: break
                }
                if !selfClosing, tag == .v || tag == .t || tag == .f {
                    textStart = k + 1
                    textTag = tag
                }
                i = k + 1
            }
        }
        return out
    }

    // MARK: - Byte helpers

    private static func find(_ byte: UInt8, in b: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard from < b.count, let base = b.baseAddress else { return nil }
        guard let p = memchr(base + from, Int32(byte), b.count - from) else { return nil }
        return base.distance(to: p.assumingMemoryBound(to: UInt8.self))
    }

    private static func find(_ s: StaticString, in b: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        var i = from
        let first = s.utf8Start.pointee
        while let p = find(first, in: b, from: i) {
            if hasPrefix(b, p, s) { return p }
            i = p + 1
        }
        return nil
    }

    private static func hasPrefix(_ b: UnsafeBufferPointer<UInt8>, _ at: Int, _ s: StaticString) -> Bool {
        let len = s.utf8CodeUnitCount
        guard at + len <= b.count else { return false }
        for k in 0..<len where b[at + k] != s.utf8Start[k] { return false }
        return true
    }

    /// Element name without its namespace prefix.
    private static func tag(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Tag {
        var s = start
        for k in start..<end where b[k] == UInt8(ascii: ":") { s = k + 1 }
        switch end - s {
        case 1:
            switch b[s] {
            case UInt8(ascii: "c"): return .c
            case UInt8(ascii: "v"): return .v
            case UInt8(ascii: "f"): return .f
            case UInt8(ascii: "t"): return .t
            default: return .other
            }
        case 3:
            if hasPrefix(b, s, "row") { return .row }
            if hasPrefix(b, s, "col") { return .col }
            return .other
        case 4:
            return hasPrefix(b, s, "pane") ? .pane : .other
        default:
            return .other
        }
    }

    /// The value range of attribute `name` (unprefixed) within a tag's attribute bytes.
    private static func attr(_ b: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, _ name: StaticString) -> Range<Int>? {
        let len = name.utf8CodeUnitCount
        var i = range.lowerBound
        while i < range.upperBound {
            // Skip whitespace to an attribute name.
            while i < range.upperBound, b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 { i += 1 }
            let nameStart = i
            while i < range.upperBound, b[i] != UInt8(ascii: "="), b[i] != 32, b[i] != UInt8(ascii: "/") { i += 1 }
            let nameEnd = i
            while i < range.upperBound, b[i] != UInt8(ascii: "\""), b[i] != UInt8(ascii: "'") {
                if b[i] == UInt8(ascii: "/") || b[i] == UInt8(ascii: ">") { return nil }
                i += 1
            }
            guard i < range.upperBound else { return nil }
            let quote = b[i]
            let valueStart = i + 1
            var j = valueStart
            while j < range.upperBound, b[j] != quote { j += 1 }
            if nameEnd - nameStart == len, hasPrefix(b, nameStart, name) { return valueStart..<j }
            i = j + 1
        }
        return nil
    }

    private static func string(_ b: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: b[r]), as: UTF8.self)
    }

    /// "AB12" straight from bytes, without building a String.
    private static func cellRef(_ b: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> CellRef? {
        var col = 0, row = 0, i = r.lowerBound
        while i < r.upperBound, b[i] == UInt8(ascii: "$") { i += 1 }
        let lettersStart = i
        while i < r.upperBound {
            let u = b[i] | 0x20
            guard u >= 97, u <= 122 else { break }
            col = col * 26 + Int(u - 96)
            i += 1
        }
        guard i > lettersStart else { return nil }
        if i < r.upperBound, b[i] == UInt8(ascii: "$") { i += 1 }
        let digitsStart = i
        while i < r.upperBound, b[i] >= 48, b[i] <= 57 { row = row * 10 + Int(b[i] - 48); i += 1 }
        guard i > digitsStart, i == r.upperBound, row >= 1 else { return nil }
        return CellRef(row: row - 1, col: col - 1)
    }

    /// Text content with XML entities decoded. Fast path when there's no "&".
    static func decode(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        guard start < end else { return "" }
        let slice = UnsafeBufferPointer(rebasing: b[start..<end])
        guard slice.contains(UInt8(ascii: "&")) else { return String(decoding: slice, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(slice.count)
        var i = 0
        while i < slice.count {
            guard slice[i] == UInt8(ascii: "&"), let semi = slice[i...].firstIndex(of: UInt8(ascii: ";")), semi - i <= 10 else {
                out.append(slice[i])
                i += 1
                continue
            }
            let entity = String(decoding: UnsafeBufferPointer(rebasing: slice[(i + 1)..<semi]), as: UTF8.self)
            var scalar: UnicodeScalar?
            switch entity {
            case "amp": scalar = "&"
            case "lt": scalar = "<"
            case "gt": scalar = ">"
            case "quot": scalar = "\""
            case "apos": scalar = "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst()).flatMap(UnicodeScalar.init)
                }
            }
            if let scalar {
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
                i = semi + 1
            } else {
                out.append(slice[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
