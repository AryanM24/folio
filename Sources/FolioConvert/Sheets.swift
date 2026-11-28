public import Foundation

/// Sheets conversions, built on Folio's spreadsheet codecs.
public nonisolated enum SheetConverter: FamilyConverter {
    public static let family: Format.Family = .spreadsheet

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome {
        throw ConvertError(.unsupportedPair, "Not implemented yet.")
    }
}
