/// PowerPoint: slide text and notes from pptx.
///
/// Step 0 stub. `DocumentFamilyConverter.delegate` (pptx) routes here, so this is the only file to fill in.
nonisolated enum SlidesConverter: FamilyConverter {
    static let family: Format.Family = .document

    static func targets(from source: Format) -> [Target] { [] }

    static func convert(_ job: Job) async throws -> Outcome { throw ConvertError.notYet(job) }
}
