public import Foundation
public import ModelIO
import SceneKit
import SceneKit.ModelIO

/// 3D model conversions, built on ModelIO and SceneKit. ModelIO reads usd/usda/usdc/usdz, obj, stl, ply and abc and
/// writes all of them but usdz, which SceneKit writes. glTF has no system reader, so Folio parses it (`GLTFReader`);
/// it is a source only.
public nonisolated enum ModelConverter: FamilyConverter {
    public static let family: Format.Family = .model

    static let writable: [Format] = [.usdz, .usda, .usdc, .obj, .stl, .ply, .abc]

    public static func targets(from source: Format) -> [Target] {
        guard source.family == .model else { return [] }
        return writable.filter { $0 != source }.map { to in
            Target(
                to: to, fidelity: .lossy, losslessAvailable: false, drops: drops(to),
                notes: to == .stl ? "Triangles only: the 3D-printing format." : nil)
        }
    }

    /// What each target can't hold. Geometry (vertices and triangles) always survives; verification checks it.
    static func drops(_ target: Format) -> [String] {
        switch target {
        case .stl: ["materials", "textures", "UVs", "normals", "scene hierarchy", "animation"]
        case .ply: ["materials", "textures", "scene hierarchy", "animation"]
        case .obj: ["scene hierarchy", "animation"]
        default: ["materials ModelIO can't map"]
        }
    }

    public static func convert(_ job: Job) async throws -> Outcome {
        try await offPool { try convertNow(job) }
    }

    static func convertNow(_ job: Job) throws -> Outcome {
        let asset = try loadAsset(job.input)
        let stats = Stats(asset)
        guard stats.triangles > 0 else { throw ConvertError(.corruptInput, "\(job.input.lastPathComponent) has no triangle meshes.") }
        if job.target == .usdz {
            // MDLAsset can't export usdz; SceneKit can.
            guard SCNScene(mdlAsset: asset).write(to: job.output, options: nil, delegate: nil, progressHandler: nil) else {
                throw ConvertError(.internal, "SceneKit couldn't write the USDZ.")
            }
        } else {
            do { try asset.export(to: job.output) } catch {
                throw ConvertError(.internal, "ModelIO couldn't write the \(job.target.title): \(error.localizedDescription)")
            }
        }
        var outcome = Outcome(fidelity: .lossy, method: "transcode", details: stats.json, dropped: drops(job.target))
        if job.verify {
            let written = (try? loadAsset(job.output)).map(Stats.init)
            outcome.verification = Verification(
                passed: written?.triangles == stats.triangles, checks: ["opens", "same triangle count"],
                metrics: ["triangles": Double(written?.triangles ?? 0)])
        }
        return outcome
    }

    public static func inspect(_ url: URL, format: Format) async throws -> [String: JSONValue] {
        try await offPool { Stats(try loadAsset(url)).json }
    }

    /// The model at `url` as a ModelIO asset (glTF through Folio's reader), for converting and previewing.
    /// Blocking: call it off the main thread and the concurrency pool.
    public static func loadAsset(_ url: URL) throws -> MDLAsset {
        let format = Format.detect(url)
        if format == .gltf || format == .glb { return try GLTFReader.asset(url) }
        guard format?.family == .model, MDLAsset.canImportFileExtension(url.pathExtension.lowercased()) else {
            throw ConvertError(.unsupportedInput, "Folio can't read \(url.lastPathComponent) as a 3D model.")
        }
        var error: NSError?
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil, preserveTopology: false, error: &error)
        if let error { throw ConvertError(.corruptInput, "\(url.lastPathComponent) couldn't be read: \(error.localizedDescription)") }
        guard asset.count > 0 else { throw ConvertError(.corruptInput, "\(url.lastPathComponent) has nothing ModelIO can read.") }
        return asset
    }

    /// Mesh counts and bounds, for `inspect`, outcomes and verification.
    struct Stats {
        var meshes = 0
        var vertices = 0
        var triangles = 0
        var bounds: MDLAxisAlignedBoundingBox

        init(_ asset: MDLAsset) {
            bounds = asset.boundingBox
            for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
                meshes += 1
                vertices += mesh.vertexCount
                for case let submesh as MDLSubmesh in mesh.submeshes ?? [] where submesh.geometryType == .triangles {
                    triangles += submesh.indexCount / 3
                }
            }
        }

        var json: [String: JSONValue] {
            let point = { (v: SIMD3<Float>) -> JSONValue in .array([.double(Double(v.x)), .double(Double(v.y)), .double(Double(v.z))]) }
            return [
                "meshes": .int(Int64(meshes)), "vertices": .int(Int64(vertices)), "triangles": .int(Int64(triangles)),
                "bounds": .object(["min": point(bounds.minBounds), "max": point(bounds.maxBounds)]),
            ]
        }
    }
}
