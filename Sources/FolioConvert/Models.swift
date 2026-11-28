/// 3D model conversions (usdz, usda, usdc, obj, stl, ply, abc), built on ModelIO and SceneKit.
///
/// Step 0 stub: no targets yet, so the engine reports UNSUPPORTED_PAIR before `convert` runs.
public nonisolated enum ModelConverter: FamilyConverter {
    public static let family: Format.Family = .model

    public static func targets(from source: Format) -> [Target] { [] }

    public static func convert(_ job: Job) async throws -> Outcome { throw ConvertError.notYet(job) }
}
