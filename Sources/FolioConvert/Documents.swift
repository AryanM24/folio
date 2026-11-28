public import Foundation

/// Documents conversions, built on the Cocoa text system and Folio's Markdown renderer.
public nonisolated enum DocumentFamilyConverter: FamilyConverter {
    public static let family: Format.Family = .document

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome {
        throw ConvertError(.unsupportedPair, "Not implemented yet.")
    }
}
