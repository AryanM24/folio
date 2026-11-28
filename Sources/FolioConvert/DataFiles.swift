/// Data and config conversions (plist, xml, toml, json5 ↔ json). YAML is detected only: there's no parser.
///
/// Step 0 stub: no targets yet, so the engine reports UNSUPPORTED_PAIR before `convert` runs.
public nonisolated enum DataConverter: FamilyConverter {
    public static let family: Format.Family = .data

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome { throw ConvertError.notYet(job) }
}
