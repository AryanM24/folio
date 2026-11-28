import AppKit
import FolioConvert
import Metal
public import SceneKit
import SceneKit.ModelIO
public import SwiftUI

/// A 3D model (usdz/usd, obj, stl, ply, abc, glTF) the viewer can orbit, zoom and pan, with SceneKit's default
/// lighting. Models load through `ModelConverter.loadAsset`, the same reader the converter uses.
public struct Model3DView: View {
    let url: URL
    @State private var scene: SCNScene?
    @State private var failure: String?

    public init(url: URL) { self.url = url }

    public var body: some View {
        Group {
            if let scene {
                SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
            } else if let failure {
                ContentUnavailableView("Can’t Show This Model", systemImage: "cube.transparent", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            do { scene = try await ModelScene.load(url) } catch { failure = error.localizedDescription }
        }
    }
}

/// Scenes and thumbnails for 3D files. ModelIO blocks, so loading runs on a GCD thread.
public nonisolated enum ModelScene {
    public static func load(_ url: URL) async throws -> SCNScene {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try scene(url) }) }
        }
    }

    /// The model as a SceneKit scene. Blocking.
    public static func scene(_ url: URL) throws -> SCNScene {
        SCNScene(mdlAsset: try ModelConverter.loadAsset(url))
    }

    /// A `size`-pixel square picture of the model on transparent, framed from above the front-right, for
    /// previews and file lists. Blocking; `nil` when there is no Metal device or the model is empty.
    public static func thumbnail(of url: URL, size: Int = 256) throws -> CGImage? {
        let scene = try scene(url)
        let (center, radius) = scene.rootNode.boundingSphere
        guard radius > 0, let device = MTLCreateSystemDefaultDevice() else { return nil }
        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.automaticallyAdjustsZRange = true
        let eye = SCNNode()
        eye.camera = camera
        let direction = simd_normalize(SIMD3<Float>(0.6, 0.5, 1))
        let distance = Float(radius) / sin(Float(camera.fieldOfView) * .pi / 360) * 1.1
        eye.simdPosition = SIMD3<Float>(center) + direction * distance
        eye.simdLook(at: SIMD3<Float>(center))
        scene.rootNode.addChildNode(eye)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = eye
        renderer.autoenablesDefaultLighting = true
        scene.background.contents = NSColor.clear
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
