public import Foundation

/// Video conversions, built on AVFoundation passthrough and VideoToolbox.
public nonisolated enum VideoConverter: FamilyConverter {
    public static let family: Format.Family = .video

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome {
        throw ConvertError(.unsupportedPair, "Not implemented yet.")
    }
}
