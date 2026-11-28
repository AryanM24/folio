/// Font conversions (ttf, otf, ttc, woff, woff2), built on CoreText and the Compression framework.
///
/// Step 0 stub: no targets yet, so the engine reports UNSUPPORTED_PAIR before `convert` runs.
public nonisolated enum FontConverter: FamilyConverter {
    public static let family: Format.Family = .font

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome { throw ConvertError.notYet(job) }
}
