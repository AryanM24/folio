import CoreGraphics
import CoreImage
import Dispatch
import Testing

@testable import FolioImage

/// Selections as masks: shape arithmetic, the wand, refinement, Vision subjects, and the
/// editor's selection commands. Off the main actor, so the mask renders don't hold up
/// other suites; Vision runs on a Dispatch queue, off the cooperative pool too.
@Suite(.timeLimit(.minutes(1))) nonisolated struct SelectionTests {
    static let size = CGSize(width: 200, height: 100)

    /// Coverage bytes, row 0 at the top.
    private func mask(
        _ spec: SelectionSpec, scale: Double = 1, pixels: CIImage? = nil, assets: (any AssetStore)? = nil
    ) throws
        -> (bytes: [UInt8], width: Int, height: Int)
    {
        let image = try SelectionRenderer.mask(spec, size: Self.size, scale: scale, pixels: pixels, assets: assets)
        return SelectionRenderer.bytes(of: image)
    }

    private func area(_ m: (bytes: [UInt8], width: Int, height: Int)) -> Int { m.bytes.count { $0 > 127 } }

    private func at(_ m: (bytes: [UInt8], width: Int, height: Int), _ x: Int, _ y: Int) -> UInt8 { m.bytes[y * m.width + x] }

    private func iou(_ a: [Bool], _ b: [Bool]) -> Double {
        let both = zip(a, b).count { $0 && $1 }, either = zip(a, b).count { $0 || $1 }
        return either == 0 ? 1 : Double(both) / Double(either)
    }

    /// A 200 × 100 image: red left half, blue right half, and a red 20 px square inside the blue.
    static func twoColor() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 150, y: 40, width: 20, height: 20))
        return ctx.makeImage()!
    }

    /// A red disc (radius 100) on gray noise, 512².
    static let disc: CGImage = {
        let n = 512
        let ctx = CGContext(
            data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var seed: UInt32 = 7
        for y in stride(from: 0, to: n, by: 4) {
            for x in stride(from: 0, to: n, by: 4) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let g = 0.3 + 0.3 * Double(seed >> 24) / 255
                ctx.setFillColor(CGColor(srgbRed: g, green: g * 0.9, blue: g * 0.8, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 156, y: 156, width: 200, height: 200))
        return ctx.makeImage()!
    }()

    // MARK: Shapes

    @Test func rectUnionEllipseMinusRect() throws {
        let rect = try mask(SelectionSpec(.rect(CGRect(x: 0, y: 0, width: 100, height: 100))))
        #expect(abs(area(rect) - 10_000) <= 100)
        #expect(at(rect, 10, 10) == 255 && at(rect, 150, 50) == 0, "left half, top-left origin")

        let spec = SelectionSpec(.rect(CGRect(x: 0, y: 0, width: 100, height: 100)))
            .adding(.ellipse(CGRect(x: 100, y: 0, width: 100, height: 100)))
            .adding(.rect(CGRect(x: 0, y: 0, width: 50, height: 100)), mode: .subtract)
        let circle = Double.pi * 50 * 50
        #expect(abs(Double(area(try mask(spec))) - (5_000 + circle)) < 150)

        let both = SelectionSpec(.rect(CGRect(x: 0, y: 0, width: 150, height: 100)))
            .adding(.rect(CGRect(x: 100, y: 0, width: 100, height: 50)), mode: .intersect)
        #expect(abs(area(try mask(both)) - 2_500) <= 100)
    }

    @Test func rectTopAndBottomFollowSourceCoordinates() throws {
        let top = try mask(SelectionSpec(.rect(CGRect(x: 0, y: 0, width: 200, height: 20))))
        #expect(at(top, 100, 5) == 255 && at(top, 100, 95) == 0)
    }

    @Test func lassoContainsItsInside() throws {
        let triangle = [CGPoint(x: 10, y: 10), CGPoint(x: 190, y: 10), CGPoint(x: 100, y: 90)]
        let m = try mask(SelectionSpec(.polygon(triangle)))
        #expect(at(m, 100, 40) == 255)
        #expect(at(m, 15, 80) == 0 && at(m, 185, 80) == 0, "outside the slanted edges")
        #expect(abs(area(m) - 180 * 80 / 2) < 200)

        var path = VectorPath()
        path.elements = [.move(to: triangle[0]), .line(to: triangle[1]), .line(to: triangle[2]), .close]
        #expect(abs(area(try mask(SelectionSpec(.path(path)))) - area(m)) < 20, "a path draws like the polygon")
        #expect(area(try mask(SelectionSpec(.polygon(Array(triangle.prefix(2)))))) == 0, "two points enclose nothing")
    }

    @Test func allInvertAndEmpty() throws {
        #expect(area(try mask(SelectionSpec(.all))) == 20_000)
        #expect(area(try mask(SelectionSpec())) == 0)
        var inverse = SelectionSpec(.rect(CGRect(x: 0, y: 0, width: 50, height: 100)))
        inverse.inverted = true
        let m = try mask(inverse)
        #expect(abs(area(m) - 15_000) <= 100)
        #expect(at(m, 10, 10) == 0 && at(m, 150, 10) == 255)
    }

    @Test func maskScalesWithScale() throws {
        let image = try SelectionRenderer.mask(SelectionSpec(.all), size: Self.size, scale: 0.5)
        #expect(image.extent == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    // MARK: Wand and color range

    @Test func wandContiguousSelectsOneRegion() throws {
        let image = Self.twoColor()
        let local = SelectionRenderer.bytes(
            of: try #require(MagicWand.mask(seed: CGPoint(x: 10, y: 10), tolerance: 0.1, contiguous: true, in: image)))
        #expect(area(local) == 10_000, "only the left half")
        #expect(at(local, 160, 50) == 0, "not the disconnected red square")

        let global = SelectionRenderer.bytes(
            of: try #require(MagicWand.mask(seed: CGPoint(x: 10, y: 10), tolerance: 0.1, contiguous: false, in: image)))
        #expect(area(global) == 10_400, "left half and the square")

        let blue = SelectionRenderer.bytes(
            of: try #require(MagicWand.mask(seed: CGPoint(x: 120, y: 10), tolerance: 0.1, contiguous: true, in: image)))
        #expect(area(blue) == 9_600, "blue around the square")
        #expect(MagicWand.mask(seed: CGPoint(x: 500, y: 10), tolerance: 0.1, contiguous: true, in: image) == nil)
    }

    @Test func wandThroughTheRenderer() throws {
        let pixels = CIImage(cgImage: Self.twoColor())
        let m = try mask(
            SelectionSpec(.wand(seed: CGPoint(x: 160, y: 50), tolerance: 0.1, contiguous: true, sampleAllLayers: true)), pixels: pixels)
        #expect(area(m) == 400, "the red square")
        #expect(at(m, 160, 50) == 255)
        let none = try mask(SelectionSpec(.wand(seed: CGPoint(x: 160, y: 50), tolerance: 0.1, contiguous: true, sampleAllLayers: true)))
        #expect(area(none) == 0, "no pixels, no wand")
    }

    @Test func colorRangeSelectsEveryMatch() throws {
        let m = try mask(
            SelectionSpec(.colorRange(RGBA(red: 1, green: 0, blue: 0), fuzziness: 0.2)), pixels: CIImage(cgImage: Self.twoColor()))
        #expect(area(m) == 10_400)
    }

    // MARK: Refinement

    @Test func featherIsMonotonic() throws {
        var spec = SelectionSpec(.rect(CGRect(x: 0, y: 0, width: 100, height: 100)))
        spec.feather = 10
        let m = try mask(spec)
        let row = (60..<140).map { at(m, $0, 50) }
        #expect(zip(row, row.dropFirst()).allSatisfy { $0 >= $1 }, "fades out without bumps")
        #expect(row.first == 255 && row.last == 0)
        #expect(at(m, 100, 50) > 100 && at(m, 100, 50) < 155, "half selected on the edge")

        var softer = spec
        softer.feather = 20
        #expect(at(try mask(softer), 110, 50) > at(m, 110, 50), "a wider feather reaches further")
    }

    @Test func expandAndContract() throws {
        var spec = SelectionSpec(.rect(CGRect(x: 50, y: 25, width: 100, height: 50)))
        let base = area(try mask(spec))
        spec.expand = 5
        #expect(area(try mask(spec)) > base + 1_000)
        spec.expand = -5
        #expect(area(try mask(spec)) < base - 1_000)
    }

    @Test func smoothRoundsCorners() throws {
        var spec = SelectionSpec(.rect(CGRect(x: 50, y: 25, width: 100, height: 50)))
        spec.smooth = 8
        let m = try mask(spec)
        #expect(at(m, 51, 26) < 128, "the corner is cut")
        #expect(at(m, 100, 50) == 255 && at(m, 100, 26) > 200, "the middle and the straight edge stay")
    }

    @Test func previewAndFullScaleAgree() throws {
        var spec = SelectionSpec(.ellipse(CGRect(x: 20, y: 10, width: 120, height: 70)))
            .adding(.rect(CGRect(x: 100, y: 40, width: 80, height: 50)))
        spec.feather = 2
        let full = try mask(spec)
        let half = try mask(spec, scale: 0.5)
        let a = (0..<20_000).map { full.bytes[$0] > 127 }
        let b = (0..<20_000).map { half.bytes[($0 / 200 / 2) * half.width + ($0 % 200) / 2] > 127 }
        #expect(iou(a, b) > 0.98)
    }

    // MARK: Saved selections

    @Test func savedSelectionRoundTrips() throws {
        let assets = InMemoryAssetStore()
        let original = try SelectionRenderer.mask(
            SelectionSpec(.rect(CGRect(x: 0, y: 0, width: 100, height: 100))), size: Self.size, scale: 1)
        let id = assets.put(try SelectionRenderer.png(of: original))
        let restored = try mask(SelectionSpec(.pixels(id)), assets: assets)
        #expect(abs(area(restored) - 10_000) <= 100)
        #expect(area(try mask(SelectionSpec(.pixels(id)))) == 0, "without the store it selects nothing")
    }

    @Test func specRoundTripsThroughJSON() throws {
        var spec = SelectionSpec(.ellipse(CGRect(x: 1, y: 2, width: 3, height: 4)))
            .adding(.wand(seed: CGPoint(x: 5, y: 6), tolerance: 0.3, contiguous: false, sampleAllLayers: true), mode: .intersect)
            .adding(.sky, mode: .subtract)
        spec.feather = 1.5
        spec.inverted = true
        #expect(try JSONDecoder().decode(SelectionSpec.self, from: JSONEncoder().encode(spec)) == spec)
    }

    // MARK: Vision

    /// `work` on a Dispatch queue: Vision blocks its thread while the model runs.
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    static func visionWorks() async -> Bool {
        do {
            _ = try await offPool { try SubjectSelector.mask(.subject(instances: nil), in: disc) }
            return true
        } catch {
            return false
        }
    }

    @Test(.enabled("Vision's foreground instance request fails on this Mac") { await visionWorks() })
    func subjectMatchesTheDisc() async throws {
        let disc = Self.disc
        let (all, label, background) = try await Self.offPool {
            let all = try SubjectSelector.mask(.subject(instances: nil), in: disc).map(SelectionRenderer.bytes(of:))
            let label = try SubjectSelector.instance(at: CGPoint(x: 256, y: 256), in: disc)
            let background = try SubjectSelector.instance(at: CGPoint(x: 5, y: 5), in: disc)
            return (all, label, background)
        }
        let m = try #require(all, "Vision found no subject")
        #expect(m.width == 512 && m.height == 512)
        let truth = (0..<(512 * 512)).map { i -> Bool in
            let x = Double(i % 512) + 0.5 - 256, y = Double(i / 512) + 0.5 - 256
            return x * x + y * y <= 100 * 100
        }
        #expect(iou(m.bytes.map { $0 > 127 }, truth) > 0.9)

        let instance = try #require(label)
        #expect(background == nil, "background has no instance")
        let one = try #require(
            try await Self.offPool { try SubjectSelector.mask(.subject(instances: [instance]), in: disc).map(SelectionRenderer.bytes(of:)) }
        )
        #expect(iou(one.bytes.map { $0 > 127 }, truth) > 0.9)
    }

    // MARK: Editor commands

    @MainActor @Test func commandsCombineAndUndo() throws {
        let model = ImageEditorModel(document: ImageDocument())
        model.combine(.rect(CGRect(x: 0, y: 0, width: 10, height: 10)), mode: .subtract)
        #expect(model.selectionState.spec == nil, "subtracting from nothing selects nothing")

        model.select(.rect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        model.select(.ellipse(CGRect(x: 20, y: 0, width: 10, height: 10)))
        #expect(model.selectionState.spec?.ops.count == 2)
        model.combine(.all, replacing: true)
        #expect(model.selectionState.spec == SelectionSpec(.all))

        model.invertSelection()
        #expect(model.selectionState.spec?.inverted == true)
        model.select(.rect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let spec = try #require(model.selectionState.spec)
        guard case .pixels = spec.ops.first?.shape else {
            Issue.record("an inverted selection is frozen before adding to it")
            return
        }
        #expect(!spec.inverted && spec.ops.count == 2)
        let area = SelectionRenderer.bytes(of: try #require(try model.selectionMask(scale: model.source.proxyScale)))
        #expect(area.bytes.count { $0 > 127 } > 0 && area.bytes.count { $0 > 127 } < 500, "nothing, plus the small rect")

        let undo = UndoManager()
        undo.groupsByEvent = false  // no run loop closes event groups in tests
        model.undoManager = undo
        undo.beginUndoGrouping()
        model.deselect()
        undo.endUndoGrouping()
        #expect(model.selectionState.spec == nil)
        undo.undo()
        #expect(model.selectionState.spec == spec)
    }
}
