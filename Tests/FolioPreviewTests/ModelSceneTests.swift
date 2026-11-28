import AppKit  // not Foundation: with Testing it needs an overlay the Command Line Tools lack
import Testing

@testable import FolioPreview

@Suite("3D preview", .timeLimit(.minutes(1)))
struct ModelSceneTests {
    @Test("An OBJ loads as a scene and renders a square thumbnail")
    func thumbnail() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-preview-\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nf 1 2 3\nf 1 2 4\nf 1 3 4\nf 2 3 4\n".utf8).write(to: url)
        #expect(try ModelScene.scene(url).rootNode.childNodes.isEmpty == false)
        let image = try ModelScene.thumbnail(of: url, size: 64)
        if let image {  // nil only without a Metal device
            #expect((image.width, image.height) == (64, 64))
        }
        #expect(throws: (any Error).self) { try ModelScene.scene(URL(fileURLWithPath: "/tmp/folio-missing.stl")) }
    }
}
