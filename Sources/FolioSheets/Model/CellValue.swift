import Foundation

/// The spreadsheet errors a formula can produce. Raw values are what cells display.
public nonisolated enum FormulaError: String, Error, Sendable, Hashable, CaseIterable {
    case ref = "#REF!"
    case div0 = "#DIV/0!"
    case name = "#NAME?"
    case value = "#VALUE!"
    case na = "#N/A"
    case num = "#NUM!"
    /// A formula that (indirectly) refers to itself.
    case circular = "#CIRC!"
    /// The formula text couldn't be parsed.
    case syntax = "#ERROR!"

    /// A short explanation for the status bar and tooltips.
    public var explanation: String {
        switch self {
        case .ref: "Refers to a cell that doesn't exist (it may have been deleted)."
        case .div0: "Divides by zero or by an empty cell."
        case .name: "Uses a function or name Folio doesn't know."
        case .value: "Uses the wrong kind of value, such as text where a number is needed."
        case .na: "A lookup didn't find a match."
        case .num: "The result isn't a valid number."
        case .circular: "Refers to itself, directly or through other cells."
        case .syntax: "The formula can't be read. Check brackets, commas and quotes."
        }
    }
}

/// A computed cell value.
public nonisolated enum CellValue: Sendable, Hashable {
    case empty
    case number(Double)
    case text(String)
    case bool(Bool)
    case error(FormulaError)

    /// What a typed literal (not a formula) means. A leading apostrophe forces text.
    ///
    /// Accepts "12", "-3.5", "1,234", "1e3", "12%", "$9.99" and TRUE/FALSE, so values
    /// pasted from other apps keep working as numbers.
    public static func literal(_ input: String) -> CellValue {
        if input.isEmpty { return .empty }
        if input.hasPrefix("'") { return .text(String(input.dropFirst())) }
        if let n = parseNumber(input) { return .number(n) }
        switch input.uppercased() {
        case "TRUE": return .bool(true)
        case "FALSE": return .bool(false)
        default: break
        }
        if let e = FormulaError(rawValue: input.uppercased()) { return .error(e) }
        return .text(input)
    }

    /// Lenient number parsing shared by literals and VALUE-style coercion.
    public static func parseNumber(_ raw: String) -> Double? {
        // Fast path: the common case of a plain number.
        // Swift also accepts hex floats ("0x1A") and "nan"/"inf", which aren't numbers to people.
        if !raw.utf8.contains(where: { ($0 | 0x20) >= 97 && ($0 | 0x20) <= 122 && ($0 | 0x20) != 101 }) {
            if let d = Double(raw) { return d.isFinite ? d : nil }
        } else {
            return nil
        }
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count < 64 else { return nil }
        var scale = 1.0
        if s.hasSuffix("%") { scale = 0.01; s.removeLast() }
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("-") { negative.toggle(); s.removeFirst() }
        if let first = s.first, "$€£¥".contains(first) { s.removeFirst() }
        if s.contains(",") {
            // Only accept commas as thousands separators ("1,234,567.8").
            let intPart = s.split(separator: ".", maxSplits: 1)[0]
            let groups = intPart.split(separator: ",", omittingEmptySubsequences: false)
            guard groups.count > 1, (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            s.removeAll { $0 == "," }
        }
        guard let first = s.first, first.isNumber || first == ".", let d = Double(s), d.isFinite else { return nil }
        return (negative ? -d : d) * scale
    }

    public var isEmpty: Bool { if case .empty = self { true } else { false } }
    public var isNumber: Bool { if case .number = self { true } else { false } }
    public var errorValue: FormulaError? { if case .error(let e) = self { e } else { nil } }

    /// Number coercion used by arithmetic: empty → 0, TRUE → 1, numeric text → its number.
    public func asNumber() -> Result<Double, FormulaError> {
        switch self {
        case .empty: .success(0)
        case .number(let n): .success(n)
        case .bool(let b): .success(b ? 1 : 0)
        case .text(let s): CellValue.parseNumber(s).map { .success($0) } ?? .failure(.value)
        case .error(let e): .failure(e)
        }
    }

    /// Text coercion used by & and text functions. Numbers print without a trailing ".0".
    public func asText() -> Result<String, FormulaError> {
        switch self {
        case .empty: .success("")
        case .number(let n): .success(CellValue.plainNumberText(n))
        case .text(let s): .success(s)
        case .bool(let b): .success(b ? "TRUE" : "FALSE")
        case .error(let e): .failure(e)
        }
    }

    public func asBool() -> Result<Bool, FormulaError> {
        switch self {
        case .empty: .success(false)
        case .number(let n): .success(n != 0)
        case .bool(let b): .success(b)
        case .text(let s):
            switch s.uppercased() {
            case "TRUE": .success(true)
            case "FALSE": .success(false)
            default: .failure(.value)
            }
        case .error(let e): .failure(e)
        }
    }

    /// Up to 15 significant digits, no exponent for everyday magnitudes, no trailing zeros.
    public static func plainNumberText(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        let magnitude = abs(n)
        if magnitude >= 1e15 || magnitude < 1e-9 {
            return String(format: "%.10G", n)
        }
        var s = String(format: "%.15G", n)
        if s.contains("."), !s.contains("E") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
