public import Foundation

/// PDF conversions, built on PDFKit and Quartz filters.
public nonisolated enum PDFConverter: FamilyConverter {
    public static let family: Format.Family = .pdf

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome {
        throw ConvertError(.unsupportedPair, "Not implemented yet.")
    }
}
