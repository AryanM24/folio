import FolioSheets
import Foundation

/// Files that read as tables: xls (BIFF8), SQLite, JSON Lines, iCalendar, vCard, GPX, KML and GeoJSON.
///
/// Step 0 stub. `SheetConverter.read(_:as:)` routes these formats here, so this file turns
/// them into a `Workbook` and the sheet codecs do the rest.
nonisolated enum SheetImport {
    static let formats: Set<Format> = [.xls, .sqlite, .jsonl, .ics, .vcf, .gpx, .kml, .geojson]

    static func workbook(_ url: URL, as format: Format) throws -> Workbook {
        throw ConvertError(.unsupportedInput, "Reading \(format.title) files as tables is coming in Folio 0.3.")
    }
}
