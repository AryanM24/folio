import Foundation

/// An sRGB color stored as 0xRRGGBB, the form every spreadsheet file format uses.
public nonisolated struct RGBColor: Hashable, Sendable, Codable {
    public var hex: UInt32
    public init(hex: UInt32) { self.hex = hex & 0xFFFFFF }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    /// "FF0000"-style, as written in XLSX (after the alpha byte) and ODS (after "#").
    public var hexString: String { String(format: "%06X", hex) }

    /// Accepts "FF0000", "#FF0000" and XLSX's "FFFF0000" (alpha first).
    public init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 8 { s.removeFirst(2) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

/// How a number is shown. Stored per cell; the raw value never changes.
public nonisolated enum NumberFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case general, number, currency, percent, date

    public var title: String {
        switch self {
        case .general: "Automatic"
        case .number: "Number"
        case .currency: "Currency"
        case .percent: "Percentage"
        case .date: "Date"
        }
    }
}

public nonisolated enum HorizontalAlignment: String, Hashable, Sendable, Codable {
    /// Text left, numbers right — what every spreadsheet does by default.
    case automatic, left, center, right
}

/// Formatting for one cell. The default value means "unstyled" and isn't stored.
public nonisolated struct CellStyle: Hashable, Sendable, Codable {
    public var bold = false
    public var italic = false
    public var underline = false
    public var alignment: HorizontalAlignment = .automatic
    public var fill: RGBColor?
    public var textColor: RGBColor?
    public var numberFormat: NumberFormat = .general

    public init(
        bold: Bool = false, italic: Bool = false, underline: Bool = false,
        alignment: HorizontalAlignment = .automatic, fill: RGBColor? = nil,
        textColor: RGBColor? = nil, numberFormat: NumberFormat = .general
    ) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.alignment = alignment
        self.fill = fill
        self.textColor = textColor
        self.numberFormat = numberFormat
    }

    public static let plain = CellStyle()
    public var isPlain: Bool { self == .plain }
}
