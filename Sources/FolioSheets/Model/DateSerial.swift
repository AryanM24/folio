public import Foundation

/// Dates as spreadsheet serial numbers in the 1900 date system (Excel, Numbers, Sheets).
///
/// Serial 1 is 1900-01-01. Excel inherited Lotus 1-2-3's bug of treating 1900 as a
/// leap year, so serial 60 is the fictional 1900-02-29 and every later serial is one
/// day "ahead". We reproduce that so files round-trip with the same dates.
public nonisolated enum DateSerial {
    /// Serial of 1970-01-01.
    static let unixEpochSerial = 25569.0

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()

    /// DATE(year, month, day) semantics: months and days overflow into the next unit,
    /// years 0–1899 are offset from 1900.
    public static func serial(year: Int, month: Int, day: Int) -> Double? {
        let y = (0..<1900).contains(year) ? year + 1900 : year
        // Normalise month overflow ourselves so negative months work like Excel.
        let totalMonths = y * 12 + (month - 1)
        let ny = Int((Double(totalMonths) / 12).rounded(.down))
        let nm = totalMonths - ny * 12 + 1
        guard let first = utc.date(from: DateComponents(year: ny, month: nm, day: 1)) else { return nil }
        let days = first.timeIntervalSince1970 / 86400 + Double(day - 1)
        let s = days + unixEpochSerial
        // Dates before 1900-03-01 sit before the phantom leap day.
        let adjusted = s < 61 ? s - 1 : s
        return adjusted >= 0 ? adjusted : nil
    }

    /// The calendar date for a serial (time of day dropped). `nil` for negatives.
    public static func components(_ serial: Double) -> (year: Int, month: Int, day: Int)? {
        guard serial >= 0, serial < 2_958_466 else { return nil }
        let whole = serial.rounded(.down)
        if whole == 60 { return (1900, 2, 29) }
        if whole == 0 { return (1900, 1, 0) }
        let real = whole < 60 ? whole + 1 : whole
        let date = Date(timeIntervalSince1970: (real - unixEpochSerial) * 86400)
        let c = utc.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return (y, m, d)
    }

    /// Serial for a moment, in the given time zone's wall-clock time (TODAY/NOW).
    public static func serial(for date: Date, timeZone: TimeZone = .current) -> Double {
        let offset = Double(timeZone.secondsFromGMT(for: date))
        return (date.timeIntervalSince1970 + offset) / 86400 + unixEpochSerial
    }

    /// A `Date` at UTC midnight for display formatting.
    public static func date(_ serial: Double) -> Date? {
        guard let c = components(serial), c.day > 0, let d = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) else {
            return nil
        }
        return d
    }

    /// Recognises ISO dates typed or read from CSV ("2024-03-15").
    public static func parseISO(_ s: String) -> Double? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, (1...2).contains(parts[1].count), (1...2).contains(parts[2].count),
            let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
            (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        return serial(year: y, month: m, day: d)
    }
}
