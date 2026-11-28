public import Foundation

/// Audio conversions, built on AVAudioFile and AudioToolbox.
public nonisolated enum AudioConverter: FamilyConverter {
    public static let family: Format.Family = .audio

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome {
        throw ConvertError(.unsupportedPair, "Not implemented yet.")
    }
}
