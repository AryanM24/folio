import Foundation
import ModelIO
import simd

/// glTF 2.0 (`.gltf` with data: URIs or buffer files beside it, and binary `.glb`) as a ModelIO asset, since neither
/// ModelIO nor SceneKit opens it. Reads triangle primitives (positions, normals, UVs, indices) and node transforms.
///
/// shortcut: no materials, textures, skins, morph targets, animation, sparse accessors or Draco; add them when
/// someone converts a model that needs them.
nonisolated enum GLTFReader {
    struct Document: Decodable {
        var scene: Int?
        var scenes: [Scene]?
        var nodes: [Node]?
        var meshes: [Mesh]?
        var accessors: [Accessor]?
        var bufferViews: [BufferView]?
        var buffers: [Buffer]?
    }
    struct Scene: Decodable { var nodes: [Int]? }
    struct Node: Decodable {
        var mesh: Int?
        var children: [Int]?
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
    }
    struct Mesh: Decodable { var primitives: [Primitive] }
    struct Primitive: Decodable {
        var attributes: [String: Int]
        var indices: Int?
        var mode: Int?
    }
    struct Accessor: Decodable {
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var count: Int
        var type: String
    }
    struct BufferView: Decodable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
    }
    struct Buffer: Decodable {
        var uri: String?
        var byteLength: Int
    }

    static func asset(_ url: URL) throws -> MDLAsset {
        let file = try Data(contentsOf: url, options: .mappedIfSafe)
        let (json, bin) = try split(file, name: url.lastPathComponent)
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: json)
        } catch {
            throw damaged(url, "its JSON doesn't parse")
        }
        let buffers = try (document.buffers ?? []).enumerated().map { index, buffer in
            try load(buffer, index: index, bin: bin, folder: url.deletingLastPathComponent(), name: url.lastPathComponent)
        }
        let reader = Reader(document: document, buffers: buffers, name: url.lastPathComponent)
        let asset = MDLAsset(bufferAllocator: MDLMeshBufferDataAllocator())
        let nodes = document.nodes ?? []
        if nodes.isEmpty {
            for index in (document.meshes ?? []).indices {
                for mesh in try reader.meshes(index) { asset.add(mesh) }
            }
        } else {
            let roots = document.scenes?[safe: document.scene ?? 0]?.nodes ?? rootNodes(nodes)
            for root in roots { asset.add(try reader.object(root, depth: 0)) }
        }
        guard asset.count > 0 else { throw damaged(url, "it has no meshes") }
        return asset
    }

    /// Nodes no other node lists as a child.
    static func rootNodes(_ nodes: [Node]) -> [Int] {
        let children = Set(nodes.flatMap { $0.children ?? [] })
        return nodes.indices.filter { !children.contains($0) }
    }

    /// The JSON and, for `.glb`, the binary chunk (12-byte header, then JSON and BIN chunks).
    static func split(_ file: Data, name: String) throws -> (json: Data, bin: Data?) {
        guard file.count >= 20, file.prefix(4) == Data("glTF".utf8) else { return (file, nil) }
        let bytes = [UInt8](file)
        func word(_ at: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        var json: Data?
        var bin: Data?
        var offset = 12
        while offset + 8 <= bytes.count {
            let length = word(offset)
            let type = word(offset + 4)
            guard offset + 8 + length <= bytes.count else { throw ConvertError(.corruptInput, "\(name) is truncated.") }
            let chunk = Data(bytes[(offset + 8)..<(offset + 8 + length)])
            if type == 0x4E4F_534A { json = json ?? chunk }
            if type == 0x004E_4942 { bin = bin ?? chunk }
            offset += 8 + length
        }
        guard let json else { throw ConvertError(.corruptInput, "\(name) has no JSON chunk.") }
        return (json, bin)
    }

    /// A buffer's bytes: the GLB binary chunk, a base64 data: URI, or a file in the model's folder.
    static func load(_ buffer: Buffer, index: Int, bin: Data?, folder: URL, name: String) throws -> Data {
        var data: Data?
        if let uri = buffer.uri, uri.hasPrefix("data:") {
            data = uri.range(of: ";base64,").flatMap { Data(base64Encoded: String(uri[$0.upperBound...])) }
        } else if let uri = buffer.uri {
            // Only files beside the model or below it: a buffer URI must not reach elsewhere on disk.
            let path = uri.removingPercentEncoding ?? uri
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw ConvertError(.unsupportedInput, "\(name) points at a buffer outside its folder.")
            }
            data = try? Data(contentsOf: folder.appending(path: path), options: .mappedIfSafe)
        } else if index == 0 {
            data = bin
        }
        guard let data, data.count >= buffer.byteLength else {
            throw ConvertError(.corruptInput, "\(name) is missing buffer \(index), or it is too short.")
        }
        return data
    }

    static func damaged(_ url: URL, _ why: String) -> ConvertError {
        ConvertError(.corruptInput, "\(url.lastPathComponent) isn't a glTF model Folio can read: \(why).")
    }

    /// Turns accessors into vertex arrays and nodes into ModelIO objects. Every read is bounds-checked.
    struct Reader {
        let document: Document
        let buffers: [Data]
        let name: String

        func object(_ index: Int, depth: Int) throws -> MDLObject {
            guard depth < 64, let node = document.nodes?[safe: index] else { throw bad("a node is missing or nests too deep") }
            let object = MDLObject()
            object.transform = MDLTransform(matrix: matrix(node))
            if let mesh = node.mesh {
                for child in try meshes(mesh) { object.addChild(child) }
            }
            for child in node.children ?? [] { object.addChild(try self.object(child, depth: depth + 1)) }
            return object
        }

        func matrix(_ node: Node) -> simd_float4x4 {
            if let m = node.matrix, m.count == 16 {
                return simd_float4x4(
                    SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]),
                    SIMD4(m[12], m[13], m[14], m[15]))
            }
            var result = matrix_identity_float4x4
            if let t = node.translation, t.count == 3 { result.columns.3 = SIMD4(t[0], t[1], t[2], 1) }
            if let r = node.rotation, r.count == 4 {
                result *= simd_float4x4(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
            }
            if let s = node.scale, s.count == 3 { result *= simd_float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1)) }
            return result
        }

        /// One `MDLMesh` per triangle primitive (mode 4, the default); points and lines are skipped.
        func meshes(_ index: Int) throws -> [MDLMesh] {
            guard let mesh = document.meshes?[safe: index] else { throw bad("mesh \(index) is missing") }
            return try mesh.primitives.filter { ($0.mode ?? 4) == 4 }.compactMap(primitive)
        }

        func primitive(_ primitive: Primitive) throws -> MDLMesh? {
            guard let positionIndex = primitive.attributes["POSITION"] else { return nil }
            let positions = try floats(positionIndex, width: 3)
            let count = positions.count / 3
            guard count > 0 else { return nil }
            var attributes: [(name: String, values: [Float], width: Int)] = [(MDLVertexAttributePosition, positions, 3)]
            if let n = primitive.attributes["NORMAL"], let normals = try? floats(n, width: 3), normals.count == positions.count {
                attributes.append((MDLVertexAttributeNormal, normals, 3))
            }
            if let t = primitive.attributes["TEXCOORD_0"], let uvs = try? floats(t, width: 2), uvs.count == count * 2 {
                attributes.append((MDLVertexAttributeTextureCoordinate, uvs, 2))
            }
            let indices = try primitive.indices.map(self.indices) ?? Array(0..<UInt32(count))
            guard indices.count >= 3, indices.allSatisfy({ Int($0) < count }) else { throw bad("an index points past its vertices") }

            let allocator = MDLMeshBufferDataAllocator()
            let descriptor = MDLVertexDescriptor()
            var vertexBuffers: [any MDLMeshBuffer] = []
            for (slot, attribute) in attributes.enumerated() {
                descriptor.attributes[slot] = MDLVertexAttribute(
                    name: attribute.name, format: attribute.width == 3 ? .float3 : .float2, offset: 0, bufferIndex: slot)
                descriptor.layouts[slot] = MDLVertexBufferLayout(stride: attribute.width * 4)
                vertexBuffers.append(allocator.newBuffer(with: attribute.values.withUnsafeBytes { Data($0) }, type: .vertex))
            }
            let triangles = Array(indices.prefix(indices.count - indices.count % 3))
            let submesh = MDLSubmesh(
                indexBuffer: allocator.newBuffer(with: triangles.withUnsafeBytes { Data($0) }, type: .index),
                indexCount: triangles.count, indexType: .uInt32, geometryType: .triangles, material: nil)
            return MDLMesh(vertexBuffers: vertexBuffers, vertexCount: count, descriptor: descriptor, submeshes: [submesh])
        }

        /// The byte offset of each element of an accessor in its buffer, honouring the view's stride.
        func offsets(_ index: Int, componentSize: Int, width: Int) throws -> (bytes: Data, offsets: [Int]) {
            guard let accessor = document.accessors?[safe: index], let viewIndex = accessor.bufferView,
                let view = document.bufferViews?[safe: viewIndex], let buffer = buffers[safe: view.buffer]
            else { throw bad("accessor \(index) is missing or sparse") }
            let element = componentSize * width
            let stride = view.byteStride ?? element
            let start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
            let end = start + stride * max(0, accessor.count - 1) + element
            let viewEnd = (view.byteOffset ?? 0) + view.byteLength
            guard accessor.count >= 0, stride >= element, start >= 0, end <= viewEnd, end <= buffer.count else {
                throw bad("accessor \(index) runs past its buffer")
            }
            return (buffer, (0..<accessor.count).map { start + $0 * stride })
        }

        func floats(_ index: Int, width: Int) throws -> [Float] {
            guard let accessor = document.accessors?[safe: index], accessor.componentType == 5126,
                accessor.type == "VEC\(width)"
            else { throw bad("accessor \(index) isn't float VEC\(width)") }
            let (bytes, offsets) = try offsets(index, componentSize: 4, width: width)
            return offsets.flatMap { offset in
                (0..<width).map { Float(bitPattern: UInt32(littleEndianAt: offset + $0 * 4, size: 4, in: bytes)) }
            }
        }

        func indices(_ index: Int) throws -> [UInt32] {
            let sizes = [5121: 1, 5123: 2, 5125: 4]
            guard let accessor = document.accessors?[safe: index], accessor.type == "SCALAR",
                let size = sizes[accessor.componentType]
            else { throw bad("accessor \(index) isn't a supported index list") }
            let (bytes, offsets) = try offsets(index, componentSize: size, width: 1)
            return offsets.map { UInt32(littleEndianAt: $0, size: size, in: bytes) }
        }

        func bad(_ why: String) -> ConvertError {
            ConvertError(.corruptInput, "\(name) isn't a glTF model Folio can read: \(why).")
        }
    }
}

extension UInt32 {
    /// A little-endian unsigned integer of `size` bytes (1, 2 or 4) at `offset`; callers bounds-check.
    nonisolated init(littleEndianAt offset: Int, size: Int, in bytes: Data) {
        self = (0..<size).reduce(0) { $0 | UInt32(bytes[bytes.startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}

extension Array {
    nonisolated subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
