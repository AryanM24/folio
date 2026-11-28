/// Archive conversions (zip, tar.*, 7z, rar, iso…), built on the system libarchive through `CArchive`.
///
/// Step 0 stub: no targets yet, so the engine reports UNSUPPORTED_PAIR before `convert` runs.
public nonisolated enum ArchiveConverter: FamilyConverter {
    public static let family: Format.Family = .archive

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome { throw ConvertError.notYet(job) }
}
