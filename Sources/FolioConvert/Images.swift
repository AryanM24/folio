public import Foundation

/// Images conversions, built on ImageIO and Core Image.
public nonisolated enum ImageConverter: FamilyConverter {
    public static let family: Format.Family = .image

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome {
        throw ConvertError(.unsupportedPair, "Not implemented yet.")
    }
}
