import Foundation

/// One end of a reference: a column and/or row, each optionally absolute ($).
///
/// `row == nil` means a whole column ("A:A"). Indices are zero-based.
public nonisolated struct RefPoint: Hashable, Sendable {
    public var col: Int
    public var row: Int?
    public var colAbsolute = false
    public var rowAbsolute = false

    public init(col: Int, row: Int?, colAbsolute: Bool = false, rowAbsolute: Bool = false) {
        self.col = col
        self.row = row
        self.colAbsolute = colAbsolute
        self.rowAbsolute = rowAbsolute
    }

    var text: String {
        var s = (colAbsolute ? "$" : "") + CellRef.columnName(col)
        if let row { s += (rowAbsolute ? "$" : "") + String(row + 1) }
        return s
    }
}

/// A cell or range reference as written in a formula, e.g. `'My Sheet'!$A$1:B3`.
public nonisolated struct Reference: Hashable, Sendable {
    public var sheet: String?
    public var start: RefPoint
    public var end: RefPoint?
    /// Set when a rewrite deleted the referenced cells; prints as `#REF!`.
    public var isDeleted = false

    public init(sheet: String? = nil, start: RefPoint, end: RefPoint? = nil) {
        self.sheet = sheet
        self.start = start
        self.end = end
    }

    var isRange: Bool { end != nil }

    /// Formula text for this reference, quoting the sheet name when needed.
    public var text: String {
        if isDeleted { return "#REF!" }
        var s = ""
        if let sheet { s += Reference.quoteSheetName(sheet) + "!" }
        s += start.text
        if let end { s += ":" + end.text }
        return s
    }

    static func quoteSheetName(_ name: String) -> String {
        let plain =
            name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            && !(name.first?.isNumber ?? true)
            && CellRef(a1: name) == nil
        return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

/// Lexical tokens of a formula (the text after "=").
nonisolated enum TokenKind: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(FormulaError)
    case reference(Reference)
    /// A function name; always followed by "(".
    case function(String)
    /// A bare word that isn't a reference or boolean (an unknown name).
    case name(String)
    case op(String)
    case lparen, rparen, comma
}

nonisolated struct Token: Equatable, Sendable {
    var kind: TokenKind
    /// The exact source text, so untouched tokens print back unchanged.
    var text: String
    /// Whitespace before the token, kept for faithful rewriting.
    var leading: String
}

/// Splits formula text into tokens. Never throws: unknown characters become a
/// `.syntax` error token so the parser reports one clear error.
nonisolated struct Tokenizer {
    private let chars: [Character]
    private var i = 0

    init(_ formula: String) { chars = Array(formula) }

    static func tokenize(_ formula: String) -> [Token] {
        var t = Tokenizer(formula)
        return t.run()
    }

    private mutating func run() -> [Token] {
        var out: [Token] = []
        while true {
            let ws = skipSpace()
            guard i < chars.count else { break }
            let start = i
            let kind = next()
            out.append(Token(kind: kind, text: String(chars[start..<i]), leading: ws))
        }
        return out
    }

    private mutating func skipSpace() -> String {
        let start = i
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        return String(chars[start..<i])
    }

    private func peek(_ k: Int = 0) -> Character? { i + k < chars.count ? chars[i + k] : nil }

    private mutating func next() -> TokenKind {
        let c = chars[i]
        switch c {
        case "(": i += 1; return .lparen
        case ")": i += 1; return .rparen
        case ",", ";": i += 1; return .comma
        case "+", "-", "*", "/", "^", "&", "%", "=":
            i += 1; return .op(String(c))
        case "<":
            i += 1
            if peek() == "=" || peek() == ">" { i += 1; return .op("<" + String(chars[i - 1])) }
            return .op("<")
        case ">":
            i += 1
            if peek() == "=" { i += 1; return .op(">=") }
            return .op(">")
        case "\"": return readString()
        case "#": return readError()
        case "'": return readQuotedSheetReference()
        default:
            if c.isNumber || (c == "." && (peek(1)?.isNumber ?? false)) { return readNumber() }
            if c.isLetter || c == "_" || c == "$" { return readWord() }
            i += 1
            return .error(.syntax)
        }
    }

    private mutating func readString() -> TokenKind {
        i += 1
        var s = ""
        while i < chars.count {
            if chars[i] == "\"" {
                if peek(1) == "\"" { s.append("\""); i += 2; continue }
                i += 1
                return .string(s)
            }
            s.append(chars[i])
            i += 1
        }
        return .error(.syntax)  // unterminated string
    }

    private mutating func readError() -> TokenKind {
        for e in FormulaError.allCases {
            let raw = Array(e.rawValue)
            if i + raw.count <= chars.count, String(chars[i..<(i + raw.count)]).uppercased() == e.rawValue {
                i += raw.count
                return .error(e)
            }
        }
        i += 1
        return .error(.syntax)
    }

    private mutating func readNumber() -> TokenKind {
        let start = i
        while let c = peek(), c.isNumber || c == "." { i += 1 }
        if let e = peek(), e == "e" || e == "E" {
            let save = i
            i += 1
            if let s = peek(), s == "+" || s == "-" { i += 1 }
            if let d = peek(), d.isNumber {
                while let d = peek(), d.isNumber { i += 1 }
            } else {
                i = save
            }
        }
        // "1:3" style row ranges aren't supported; a number followed by ":" is a syntax error later.
        guard let n = Double(String(chars[start..<i])) else { return .error(.syntax) }
        return .number(n)
    }

    private mutating func readQuotedSheetReference() -> TokenKind {
        i += 1
        var name = ""
        while i < chars.count {
            if chars[i] == "'" {
                if peek(1) == "'" { name.append("'"); i += 2; continue }
                i += 1
                break
            }
            name.append(chars[i])
            i += 1
        }
        guard peek() == "!" else { return .error(.syntax) }
        i += 1
        return readReference(sheet: name) ?? .error(.syntax)
    }

    private mutating func readWord() -> TokenKind {
        let start = i
        // A word may contain letters, digits, "_", ".", and "$" (for $A$1).
        while let c = peek(), c.isLetter || c.isNumber || c == "_" || c == "." || c == "$" { i += 1 }
        let word = String(chars[start..<i])
        if peek() == "!" {
            i += 1
            return readReference(sheet: word) ?? .error(.syntax)
        }
        if peek() == "(", !word.contains("$") { return .function(word.uppercased()) }
        // Re-read as a reference from the word's start.
        let afterWord = i
        i = start
        if let ref = readReference(sheet: nil) { return ref }
        i = afterWord
        switch word.uppercased() {
        case "TRUE": return .bool(true)
        case "FALSE": return .bool(false)
        default: return .name(word)
        }
    }

    /// Reads `A1`, `$A$1`, `A1:B2` or `A:C` at the cursor. Restores the cursor on failure.
    private mutating func readReference(sheet: String?) -> TokenKind? {
        let save = i
        guard let first = readPoint() else { i = save; return nil }
        var ref = Reference(sheet: sheet, start: first)
        if peek() == ":" {
            let beforeColon = i
            i += 1
            if let second = readPoint(), (second.row == nil) == (first.row == nil) {
                ref.end = second
            } else {
                i = beforeColon
            }
        }
        // A whole-column reference needs both ends ("A:A"); a lone "A" is a name.
        if ref.start.row == nil && ref.end == nil { i = save; return nil }
        // Reject things like "A1B" (would be a name).
        if let c = peek(), c.isLetter || c.isNumber || c == "_" || c == "(" { i = save; return nil }
        return .reference(ref)
    }

    private mutating func readPoint() -> RefPoint? {
        let save = i
        var colAbs = false, rowAbs = false
        if peek() == "$" { colAbs = true; i += 1 }
        let lettersStart = i
        while let c = peek(), c.isASCII, c.isLetter { i += 1 }
        guard i > lettersStart, i - lettersStart <= 3,
            let col = CellRef.columnIndex(String(chars[lettersStart..<i])), col < 16384
        else { i = save; return nil }
        if peek() == "$" { rowAbs = true; i += 1 }
        let digitsStart = i
        while let c = peek(), c.isASCII, c.isNumber { i += 1 }
        if i == digitsStart {
            // Whole column; "$A$" is invalid.
            if rowAbs { i = save; return nil }
            return RefPoint(col: col, row: nil, colAbsolute: colAbs)
        }
        guard let row = Int(String(chars[digitsStart..<i])), row >= 1, row <= 1_048_576 else { i = save; return nil }
        return RefPoint(col: col, row: row - 1, colAbsolute: colAbs, rowAbsolute: rowAbs)
    }
}
