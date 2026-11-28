import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import Testing

@testable import FolioConvert

/// 3D conversions. Fixtures are written as text (OBJ, glTF) or assembled bytes (GLB) at test time.
@Suite("Models", .timeLimit(.minutes(2)))
struct ModelConverterTests {
    /// A unit cube: 8 vertices, 6 quads (12 triangles once triangulated).
    static let cube = """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        v 0 0 1
        v 1 0 1
        v 1 1 1
        v 0 1 1
        f 1 4 3 2
        f 5 6 7 8
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 4 1 5 8

        """

    /// One triangle as glTF JSON whose buffer is `uri` (a data: URI, a file name, or nil for a GLB chunk).
    static func triangle(uri: String?, indices: [UInt16] = [0, 1, 2]) -> (json: String, buffer: Data) {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        var buffer = positions.withUnsafeBytes { Data($0) }
        buffer += indices.withUnsafeBytes { Data($0) }
        buffer += Data(repeating: 0, count: (4 - buffer.count % 4) % 4)
        let source = uri.map { ",\"uri\":\"\($0)\"" } ?? ""
        let json = """
            {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0,"translation":[1,2,3]}],
            "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
            "buffers":[{"byteLength":\(buffer.count)\(source)}],
            "bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],
            "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
            {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}]}
            """
        return (json, buffer)
    }

    func convert(_ input: URL, to target: Format) async throws -> ConvertResult {
        let request = ConvertRequest(
            inputs: [input], target: target, outputDirectory: input.deletingLastPathComponent().appending(path: target.rawValue),
            verify: true)
        let result = try #require(await Engine.run(request).results.first)
        #expect(result.status == .ok, "\(input.lastPathComponent) → \(target): \(String(describing: result.error))")
        #expect(result.verification?.passed == true, "\(target)")
        return result
    }

    @Test("Targets: every ModelIO writer plus usdz, never the source itself, and glTF is read-only")
    func targets() {
        #expect(Set(ModelConverter.targets(from: .obj).map(\.to)) == [.usdz, .usda, .usdc, .stl, .ply, .abc])
        #expect(ModelConverter.targets(from: .glb).contains { $0.to == .usdz })
        for format in Format.allCases where format.family == .model {
            #expect(!ModelConverter.targets(from: format).contains { [.gltf, .glb, format].contains($0.to) })
        }
        #expect(ModelConverter.targets(from: .stl).first { $0.to == .obj }?.losslessAvailable == false)
    }

    @Test("OBJ → STL → PLY → USDZ → OBJ keeps all 12 triangles, verified at every step")
    func roundTrip() async throws {
        let dir = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var current = dir.appending(path: "cube.obj")
        try Data(Self.cube.utf8).write(to: current)
        let facts = await Engine.inspect(current)
        #expect(facts.meta["triangles"] == 12)
        #expect(facts.meta["vertices"] == 8)
        #expect(facts.meta["bounds"] == .object(["min": .array([0.0, 0.0, 0.0]), "max": .array([1.0, 1.0, 1.0])]))
        for target in [Format.stl, .ply, .usdz, .obj, .usda, .usdc, .abc] {
            let result = try await convert(current, to: target)
            #expect(result.details["triangles"] == 12, "\(target)")
            current = try output(result)
            #expect(current.pathExtension == target.fileExtension)
        }
        #expect(await Engine.inspect(current).meta["triangles"] == 12)
    }

    @Test("glTF with a data: URI, glTF with a buffer file and GLB all read, keeping node transforms")
    func gltf() async throws {
        let dir = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let embedded = Self.triangle(uri: nil)
        let dataURI = Self.triangle(uri: "data:application/octet-stream;base64,\(embedded.buffer.base64EncodedString())")
        try Data(dataURI.json.utf8).write(to: dir.appending(path: "inline.gltf"))
        let external = Self.triangle(uri: "tri.bin")
        try Data(external.json.utf8).write(to: dir.appending(path: "external.gltf"))
        try external.buffer.write(to: dir.appending(path: "tri.bin"))
        try Self.glb(json: embedded.json, bin: embedded.buffer).write(to: dir.appending(path: "binary.glb"))

        for name in ["inline.gltf", "external.gltf", "binary.glb"] {
            let url = dir.appending(path: name)
            let facts = await Engine.inspect(url)
            #expect(facts.meta["triangles"] == 1, "\(name): \(String(describing: facts.error))")
            #expect(facts.meta["bounds"] == .object(["min": .array([1.0, 2.0, 3.0]), "max": .array([2.0, 3.0, 3.0])]), "\(name)")
            _ = try await convert(url, to: .obj)
            _ = try await convert(url, to: .usdz)
        }
    }

    @Test("Damaged glTF fails with CORRUPT_INPUT; a buffer outside the folder is refused")
    func damagedGLTF() async throws {
        let dir = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pastEnd = Self.triangle(uri: nil, indices: [0, 1, 7])
        try Self.glb(json: pastEnd.json, bin: pastEnd.buffer).write(to: dir.appending(path: "bad.glb"))
        try Data("{ not json".utf8).write(to: dir.appending(path: "junk.gltf"))
        try Data(Self.triangle(uri: "../secret.bin").json.utf8).write(to: dir.appending(path: "escape.gltf"))
        let inputs = ["bad.glb", "junk.gltf", "escape.gltf"].map { dir.appending(path: $0) }
        let report = await Engine.run(ConvertRequest(inputs: inputs, target: .obj))
        #expect(report.results.map { $0.error?.code } == [.corruptInput, .corruptInput, .unsupportedInput])
    }

    /// A GLB container: header, JSON chunk (space-padded), BIN chunk.
    static func glb(json: String, bin: Data) -> Data {
        func le(_ value: Int) -> Data { Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
        var text = Data(json.utf8)
        text += Data(repeating: 0x20, count: (4 - text.count % 4) % 4)
        let body = le(text.count) + Data("JSON".utf8) + text + le(bin.count) + Data("BIN".utf8) + Data([0]) + bin
        return Data("glTF".utf8) + le(2) + le(12 + body.count) + body
    }
}
