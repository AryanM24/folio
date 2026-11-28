/// Matroska and WebM: a pure-Swift demuxer that hands samples to AVAssetWriter (remux to MOV/MP4).
///
/// Step 0 stub. `VideoConverter.delegate` (mkv, webm) routes here, so this is the only file to fill in.
nonisolated enum MatroskaConverter: FamilyConverter {
    static let family: Format.Family = .video

    static func targets(from source: Format) -> [Target] { [] }

    static func convert(_ job: Job) async throws -> Outcome { throw ConvertError.notYet(job) }
}
