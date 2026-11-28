/// Subtitle conversions (srt, vtt, ass), plus extracting and muxing subtitle tracks.
///
/// Step 0 stub: no targets yet, so the engine reports UNSUPPORTED_PAIR before `convert` runs.
public nonisolated enum SubtitleConverter: FamilyConverter {
    public static let family: Format.Family = .subtitle

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome { throw ConvertError.notYet(job) }
}
