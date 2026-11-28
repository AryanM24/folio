/// EPUB: read the spine into one attributed string, and write EPUB from any document.
///
/// Step 0 stub. `DocumentFamilyConverter.delegate` (epub as source or target) routes here, so this is the only file to fill in.
nonisolated enum EbookConverter: FamilyConverter {
    static let family: Format.Family = .document

    static func targets(from source: Format) -> [Target] { [] }

    static func convert(_ job: Job) async throws -> Outcome { throw ConvertError.notYet(job) }
}
