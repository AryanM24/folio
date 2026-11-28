/// Mail: eml (headers, sanitized body, attachments) and mbox (one message per `From ` line).
///
/// Step 0 stub. `DocumentFamilyConverter.delegate` (eml, mbox) routes here, so this is the only file to fill in.
nonisolated enum MailConverter: FamilyConverter {
    static let family: Format.Family = .document

    static func targets(from source: Format) -> [Target] { [] }

    static func convert(_ job: Job) async throws -> Outcome { throw ConvertError.notYet(job) }
}
