public import Foundation

/// Turns a computed value plus its number format into the text a cell shows.
///
/// Formatters are expensive to create, so one instance is shared per locale and
/// reused for every cell drawn.
public nonisolated final class ValueFormatter: @unchecked Sendable {
    // @unchecked: the NumberFormatter/DateFormatter instances are configured once in
    // `init` and only read afterwards; Foundation documents formatters as thread-safe
    // for formatting once configured.
    private let number: NumberFormatter
    private let currency: NumberFormatter
    private let percent: NumberFormatter
    private let date: DateFormatter

    public init(locale: Locale = .current) {
        number = NumberFormatter()
        number.locale = locale
        number.numberStyle = .decimal
        number.minimumFractionDigits = 2
        number.maximumFractionDigits = 2
        currency = NumberFormatter()
        currency.locale = locale
        currency.numberStyle = .currency
        percent = NumberFormatter()
        percent.locale = locale
        percent.numberStyle = .percent
        percent.maximumFractionDigits = 2
        date = DateFormatter()
        date.locale = locale
        date.timeZone = TimeZone(identifier: "UTC")
        date.dateStyle = .medium
        date.timeStyle = .none
    }

    public static let shared = ValueFormatter()

    public func string(for value: CellValue, format: NumberFormat) -> String {
        switch value {
        case .empty: return ""
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e.rawValue
        case .number(let n): return string(for: n, format: format)
        }
    }

    public func string(for n: Double, format: NumberFormat) -> String {
        switch format {
        case .general: return Self.general(n)
        case .number: return number.string(from: n as NSNumber) ?? Self.general(n)
        case .currency: return currency.string(from: n as NSNumber) ?? Self.general(n)
        case .percent: return percent.string(from: n as NSNumber) ?? Self.general(n)
        case .date:
            guard let d = DateSerial.date(n) else { return Self.general(n) }
            return date.string(from: d)
        }
    }

    /// "General": up to 10 significant digits, switching to scientific for huge or tiny values.
    public static func general(_ n: Double) -> String {
        if n == 0 { return "0" }
        let a = abs(n)
        if a >= 1e11 || a < 1e-9 { return String(format: "%.5E", n) }
        if n == n.rounded(), a < 1e15 { return String(Int64(n)) }
        var s = String(format: "%.10G", n)
        if s.contains("."), !s.contains("E") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
