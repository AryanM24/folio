import CoreGraphics
import CoreImage
import Testing
import UniformTypeIdentifiers

@testable import FolioImage

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// A solid sRGB color (0…1) over `size` pixels.
private func solid(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1, size: CGSize = CGSize(width: 8, height: 8)) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: sRGB)!).cropped(to: CGRect(origin: .zero, size: size))
}

/// RGBA 0…255 at (x, y) from the top-left of `image`'s extent.
private func pixel(_ image: CIImage, x: Int = 0, y: Int = 0) throws -> (r: Int, g: Int, b: Int, a: Int) {
    let cg = try RenderPipeline.rasterize(image, extent: image.extent, format: .RGBA8, colorSpace: sRGB)
    return TestImages.pixel(cg, x: x, y: y)
}

private func close(_ got: (r: Int, g: Int, b: Int, a: Int), _ want: (Int, Int, Int), tolerance: Int = 2) -> Bool {
    abs(got.r - want.0) <= tolerance && abs(got.g - want.1) <= tolerance && abs(got.b - want.2) <= tolerance
}

/// Layers over a 40 × 20 document of `base` color.
private func composite(
    _ layers: [Layer], base: CIImage = solid(0, 0, 1, size: CGSize(width: 40, height: 20)), assets: any AssetStore = InMemoryAssetStore()
) -> CIImage {
    LayerCompositor.composite(base: base, layers: layers, assets: assets, scale: 1)
}

private let leftHalf = VectorPath(elements: [
    .move(to: .zero), .line(to: CGPoint(x: 20, y: 0)), .line(to: CGPoint(x: 20, y: 20)), .line(to: CGPoint(x: 0, y: 20)), .close,
])

@Suite(.timeLimit(.minutes(1))) struct BlendModeTests {
    // Hand-computed with Photoshop's formulas on sRGB values: top (0.7, 0.35, 0.1) over
    // backdrop (0.2, 0.6, 0.85), and top (0.8, 0.4, 0.2) over (0.3, 0.6, 0.9).
    static let first: [Layer.BlendMode: (Int, Int, Int)] = [
        .normal: (179, 89, 26), .darken: (51, 89, 26), .multiply: (36, 54, 22), .colorBurn: (0, 0, 0), .linearBurn: (0, 0, 0),
        .darkerColor: (178, 89, 26), .lighten: (178, 153, 217), .screen: (194, 189, 221), .colorDodge: (170, 235, 241),
        .linearDodge: (229, 242, 242), .lighterColor: (51, 153, 217), .overlay: (71, 122, 186), .softLight: (76, 135, 191),
        .hardLight: (133, 107, 43), .vividLight: (85, 109, 64), .linearLight: (153, 76, 13), .pinLight: (102, 153, 51),
        .hardMix: (0, 0, 0), .difference: (127, 64, 191), .exclusion: (158, 135, 199), .subtract: (0, 64, 191),
        .divide: (73, 255, 255), .hue: (205, 108, 39), .saturation: (57, 151, 210), .color: (199, 110, 46),
        .luminosity: (31, 133, 196),
    ]
    static let second: [Layer.BlendMode: (Int, Int, Int)] = [
        .colorBurn: (32, 0, 128), .linearBurn: (26, 0, 26), .colorDodge: (255, 255, 255), .hardMix: (255, 255, 255),
        .softLight: (114, 141, 216), .vividLight: (191, 128, 191), .divide: (96, 255, 255), .luminosity: (65, 142, 218),
    ]

    @Test func kernelsCompileWithoutXcode() {
        #expect(BlendKernels.blend != nil)
        #expect(BlendKernels.mixKernel != nil)
        #expect(BlendKernels.lumaKernel != nil)
        #expect(Kernels.kernel(named: "folioGradient", in: GradientRenderer.source) != nil)
    }

    @Test(arguments: Layer.BlendMode.allCases.filter { $0 != .dissolve })
    func modeMatchesHandComputedPixel(_ mode: Layer.BlendMode) throws {
        let got = try pixel(mode.blend(solid(0.7, 0.35, 0.1), over: solid(0.2, 0.6, 0.85)))
        let want = try #require(Self.first[mode])
        #expect(close(got, want), "\(mode): got \(got), want \(want)")
        #expect(got.a == 255)
        if let want = Self.second[mode] {
            let got = try pixel(mode.blend(solid(0.8, 0.4, 0.2), over: solid(0.3, 0.6, 0.9)))
            #expect(close(got, want), "\(mode): got \(got), want \(want)")
        }
    }

    @Test func overlayQuarterOverHalfIsQuarter() throws {
        let got = try pixel(Layer.BlendMode.overlay.blend(solid(0.25, 0.25, 0.25), over: solid(0.5, 0.5, 0.5)))
        #expect(close(got, (64, 64, 64)))
    }

    @Test func transparentTopLeavesBackdrop() throws {
        for mode in Layer.BlendMode.allCases {
            #expect(close(try pixel(mode.blend(solid(1, 1, 1, 0), over: solid(0.2, 0.4, 0.6))), (51, 102, 153)), "\(mode)")
        }
    }

    @Test func dissolveScattersPixelsByAlpha() throws {
        let size = CGSize(width: 64, height: 64)
        let image = Layer.BlendMode.dissolve.blend(solid(1, 1, 1, 0.5, size: size), over: solid(0, 0, 0, size: size))
        let cg = try RenderPipeline.rasterize(image, extent: image.extent, format: .RGBA8, colorSpace: sRGB)
        var white = 0
        for y in 0..<64 { for x in 0..<64 where TestImages.pixel(cg, x: x, y: y).r > 250 { white += 1 } }
        #expect((1200...2900).contains(white), "about half the pixels: \(white)")
    }

    /// Photoshop fades in gamma space: white at 50 % over black is 128, not linear light's 188.
    @Test(arguments: [(0.0, 0), (0.5, 128), (1.0, 255)])
    func opacityFadesInGammaSpace(_ opacity: Double, _ expected: Int) throws {
        let got = try pixel(Layer.BlendMode.normal.blend(solid(1, 1, 1), over: solid(0, 0, 0), opacity: opacity))
        #expect(close(got, (expected, expected, expected)), "\(got)")
        let mixed = try pixel(BlendKernels.mix(solid(0, 0, 0), solid(1, 1, 1), amount: opacity))
        #expect(close(mixed, (expected, expected, expected)), "\(mixed)")
    }
}

@Suite(.timeLimit(.minutes(1))) struct LayerCompositorTests {
    static let red = RGBA(red: 1, green: 0, blue: 0)

    @Test func layerOpacityAndFillOpacity() throws {
        var layer = Layer(name: "Red", content: .fill(.solid(Self.red)))
        layer.opacity = 0.5
        #expect(close(try pixel(composite([layer])), (128, 0, 128)))
        layer.opacity = 1
        layer.fillOpacity = 0.5
        #expect(close(try pixel(composite([layer])), (128, 0, 128)))
        layer.isVisible = false
        #expect(close(try pixel(composite([layer])), (0, 0, 255)))
    }

    @Test func maskDensityAndInversion() throws {
        var layer = Layer(name: "Red", content: .fill(.solid(Self.red)))
        layer.mask = LayerMask(source: .vector(leftHalf), density: 0.5)
        let out = composite([layer])
        #expect(close(try pixel(out, x: 5, y: 10), (255, 0, 0)), "inside the mask")
        #expect(close(try pixel(out, x: 35, y: 10), (128, 0, 128)), "half hidden at density 0.5")
        layer.mask?.density = 1
        layer.mask?.inverted = true
        let inverted = composite([layer])
        #expect(close(try pixel(inverted, x: 5, y: 10), (0, 0, 255)))
        #expect(close(try pixel(inverted, x: 35, y: 10), (255, 0, 0)))
        layer.mask?.isEnabled = false
        #expect(close(try pixel(composite([layer]), x: 5, y: 10), (255, 0, 0)))
    }

    @Test func featheredMaskIsSoftAtTheEdge() throws {
        var layer = Layer(name: "Red", content: .fill(.solid(Self.red)))
        layer.mask = LayerMask(source: .vector(leftHalf), feather: 3)
        let edge = try pixel(composite([layer]), x: 20, y: 10)
        #expect(edge.r > 60 && edge.r < 200, "\(edge)")
    }

    @Test func luminanceMaskFollowsTheBackdrop() throws {
        var layer = Layer(name: "Red", content: .fill(.solid(Self.red)))
        layer.mask = LayerMask(source: .luminance(low: 0.5, high: 1))
        let dark = solid(0.1, 0.1, 0.1, size: CGSize(width: 40, height: 20))
        #expect(close(try pixel(composite([layer], base: dark)), (26, 26, 26)), "dark pixels stay unmasked out")
        let light = solid(0.9, 0.9, 0.9, size: CGSize(width: 40, height: 20))
        #expect(close(try pixel(composite([layer], base: light)), (255, 0, 0)))
    }

    @Test func clippingMaskUsesTheAlphaBelow() throws {
        let green = RGBA(red: 0, green: 1, blue: 0)
        let shape = Layer(name: "Box", content: .shape(ShapeSpec(geometry: .path(leftHalf), fill: .solid(green))))
        var clipped = Layer(name: "Red", content: .fill(.solid(Self.red)))
        clipped.clipsToBelow = true
        let out = composite([shape, clipped])
        #expect(close(try pixel(out, x: 5, y: 10), (255, 0, 0)), "red inside the shape")
        #expect(close(try pixel(out, x: 35, y: 10), (0, 0, 255)), "base outside it")
        var hidden = shape
        hidden.isVisible = false
        #expect(close(try pixel(composite([hidden, clipped]), x: 5, y: 10), (0, 0, 255)), "hidden base hides its clipped layers")
    }

    @Test func passThroughGroupsBlendIntoTheStackIsolatedOnesDont() throws {
        var child = Layer(name: "Gray", content: .fill(.solid(RGBA(red: 0.5, green: 0.5, blue: 0.5))))
        child.blend = .multiply
        let base = solid(0.5, 0.5, 0.5, size: CGSize(width: 40, height: 20))
        let through = Layer(name: "G", content: .group(GroupSpec(layers: [child], passThrough: true)))
        #expect(close(try pixel(composite([through], base: base)), (64, 64, 64)))
        let isolated = Layer(name: "G", content: .group(GroupSpec(layers: [child], passThrough: false)))
        #expect(close(try pixel(composite([isolated], base: base)), (128, 128, 128)))
    }

    @Test func adjustmentLayersProcessWhatsBelow() throws {
        var a = Adjustments()
        a[.exposure] = 50
        let layer = Layer(name: "Brighter", content: .adjustment(.adjustments(a)))
        let out = try pixel(composite([layer], base: solid(0.3, 0.3, 0.3, size: CGSize(width: 40, height: 20))))
        #expect(out.r > 100, "\(out)")
    }

    @Test func layerTransformMovesContentInSourcePixels() throws {
        var layer = Layer(
            name: "Box",
            content: .shape(
                ShapeSpec(geometry: .rectangle(CGRect(x: 0, y: 0, width: 4, height: 4), cornerRadius: 0), fill: .solid(Self.red))))
        layer.transform = CGAffineTransform(translationX: 30, y: 12)
        let out = composite([layer])
        #expect(close(try pixel(out, x: 32, y: 14), (255, 0, 0)), "moved to (30, 12) from the top-left")
        #expect(close(try pixel(out, x: 2, y: 2), (0, 0, 255)))
        #expect(LayerCompositor.bounds(of: layer, assets: InMemoryAssetStore()).contains(CGPoint(x: 32, y: 14)))
    }

    @Test func pixelLayersPlaceTheirImageTopLeft() throws {
        let store = InMemoryAssetStore()
        let id = store.put(TestImages.data(.png, width: 20, height: 10))
        var layer = Layer(name: "Pasted", content: .pixels(id))
        layer.transform = CGAffineTransform(translationX: 10, y: 5)
        let out = composite([layer], assets: store)
        // The test image has a white square in its top-left quarter.
        #expect(close(try pixel(out, x: 12, y: 6), (255, 255, 255)))
        #expect(close(try pixel(out, x: 2, y: 2), (0, 0, 255)), "outside the image")
        #expect(LayerCompositor.bounds(of: layer, assets: store) == CGRect(x: 10, y: 5, width: 20, height: 10))
    }

    @Test func gradientRunsBetweenItsPoints() throws {
        let spec = GradientSpec(
            stops: [ColorStop(location: 0, color: RGBA(red: 0, green: 0, blue: 0)), ColorStop(location: 1, color: .white)],
            start: CGPoint(x: 0, y: 10), end: CGPoint(x: 40, y: 10))
        let out = composite([Layer(name: "G", content: .fill(.gradient(spec)))])
        #expect(try pixel(out, x: 1, y: 10).r < 20)
        #expect(try pixel(out, x: 38, y: 10).r > 235)
        #expect(abs(try pixel(out, x: 20, y: 10).r - 128) < 10, "stops interpolate in sRGB")
    }

    @Test func effectsDrawAroundTheLayer() throws {
        let box = CGRect(x: 10, y: 5, width: 10, height: 10)
        var layer = Layer(name: "Box", content: .shape(ShapeSpec(geometry: .rectangle(box, cornerRadius: 0), fill: .solid(.white))))
        layer.effects = [.stroke(StrokeEffect(color: Self.red, width: 3, position: .outside))]
        let stroked = composite([layer])
        #expect(close(try pixel(stroked, x: 8, y: 10), (255, 0, 0)), "outside stroke")
        #expect(close(try pixel(stroked, x: 15, y: 10), (255, 255, 255)), "content on top")
        layer.effects = [.dropShadow(ShadowEffect(opacity: 1, angle: 90, distance: 4, blur: 0, blend: .normal))]
        let shadowed = composite([layer])
        #expect(close(try pixel(shadowed, x: 15, y: 17), (0, 0, 0)), "shadow below (light from the top)")
        #expect(close(try pixel(shadowed, x: 15, y: 2), (0, 0, 255)))
    }

    @Test func paintStrokesPaintAndEraserErases() throws {
        let line = [BrushStroke.Point(location: CGPoint(x: 2, y: 10)), BrushStroke.Point(location: CGPoint(x: 38, y: 10))]
        var paint = PaintSpec(strokes: [BrushStroke(points: line, color: Self.red, size: 6, hardness: 1)])
        let painted = composite([Layer(name: "Paint", content: .paint(paint))])
        #expect(close(try pixel(painted, x: 20, y: 10), (255, 0, 0)))
        #expect(close(try pixel(painted, x: 20, y: 2), (0, 0, 255)))
        paint.strokes.append(
            BrushStroke(points: [BrushStroke.Point(location: CGPoint(x: 20, y: 10))], size: 6, hardness: 1, isEraser: true))
        let erased = composite([Layer(name: "Paint", content: .paint(paint))])
        #expect(close(try pixel(erased, x: 20, y: 10), (0, 0, 255)), "erased back to the base")
        #expect(close(try pixel(erased, x: 5, y: 10), (255, 0, 0)))
        let light = BrushStroke(points: line.map { BrushStroke.Point(location: $0.location, pressure: 0.2) }, size: 10, hardness: 1)
        let thin = PaintRenderer.image(PaintSpec(strokes: [light]), assets: InMemoryAssetStore(), scale: 1)!
        #expect(try pixel(thin, x: 15, y: 1).a == 0, "low pressure paints a thin line")
    }

    @Test func textLayerBoundingBox() throws {
        let point = TextSpec(runs: [TextRun(text: "Hello", size: 40)])
        let size = TextRenderer.size(of: point)
        #expect(size.width > 80 && size.width < 140, "\(size)")
        #expect(size.height > 40 && size.height < 60, "\(size)")
        let image = try #require(TextRenderer.image(point, scale: 1))
        #expect(abs(image.extent.width - size.width) <= 2 && abs(image.extent.height - size.height) <= 2)
        var layer = Layer(name: "T", content: .text(point))
        layer.transform = CGAffineTransform(translationX: 5, y: 7)
        let bounds = LayerCompositor.bounds(of: layer, assets: InMemoryAssetStore())
        #expect(bounds.origin == CGPoint(x: 5, y: 7) && bounds.size == size)
        var area = point
        area.box = CGSize(width: 60, height: 200)
        #expect(TextRenderer.size(of: area) == CGSize(width: 60, height: 200))
        #expect(TextRenderer.image(TextSpec(runs: [TextRun(text: "")]), scale: 1) == nil)
    }

    @Test func textDrawsGlyphsAndGradientFill() throws {
        let spec = TextSpec(runs: [TextRun(text: "███", fontName: "Menlo-Regular", size: 30, color: Self.red)])
        let image = try #require(TextRenderer.image(spec, scale: 1))
        let middle = try pixel(image, x: Int(image.extent.width / 2), y: Int(image.extent.height / 2))
        #expect(close(middle, (255, 0, 0)), "\(middle)")
        var gradient = spec
        gradient.fill = .solid(RGBA(red: 0, green: 0, blue: 1))
        let blue = try pixel(
            try #require(TextRenderer.image(gradient, scale: 1)), x: Int(image.extent.width / 2), y: Int(image.extent.height / 2))
        #expect(close(blue, (0, 0, 255)), "\(blue)")
        var onPath = spec
        onPath.path = VectorPath(elements: [
            .move(to: CGPoint(x: 0, y: 50)),
            .curve(to: CGPoint(x: 200, y: 50), control1: CGPoint(x: 60, y: 0), control2: CGPoint(x: 140, y: 0)),
        ])
        #expect(TextRenderer.image(onPath, scale: 1) != nil)
    }

    @Test func everyShapeDraws() {
        let box = CGRect(x: 0, y: 0, width: 50, height: 40)
        let geometries: [ShapeSpec.Geometry] = [
            .rectangle(box, cornerRadius: 6), .ellipse(box), .polygon(box, sides: 6), .star(box, points: 5, innerRadius: 0.4),
            .speechBubble(box, tail: CGPoint(x: 60, y: 60)), .path(leftHalf),
            .line(from: .zero, to: CGPoint(x: 40, y: 30), startHead: .curved, endHead: .closed),
        ]
        for geometry in geometries {
            let shape = ShapeSpec(geometry: geometry, fill: .solid(Self.red), stroke: StrokeSpec(width: 2, dash: [4, 2]))
            #expect(ShapeRenderer.image(shape, scale: 1) != nil, "\(geometry)")
        }
        #expect(ShapeRenderer.image(ShapeSpec(geometry: .ellipse(box)), scale: 1) == nil, "no fill, no stroke")
    }

    /// The Phase 0 promise: a layered recipe renders the same for the preview and the save.
    @Test func previewAndSaveAgree() throws {
        let source = try SourceImage(data: TestImages.data(.png))
        let store = InMemoryAssetStore()
        var recipe = EditRecipe()
        var pasted = Layer(name: "Image", content: .pixels(store.put(TestImages.data(.png, width: 60, height: 40))))
        pasted.transform = CGAffineTransform(translationX: 200, y: 100)
        var text = Layer(name: "Text", content: .text(TextSpec(runs: [TextRun(text: "Folio", color: .white)])))
        text.transform = CGAffineTransform(translationX: 20, y: 200)
        var shape = Layer(
            name: "Shape",
            content: .shape(ShapeSpec(geometry: .ellipse(CGRect(x: 250, y: 20, width: 100, height: 60)), fill: .solid(Self.red))))
        shape.blend = .multiply
        var adjust = Adjustments()
        adjust[.contrast] = 30
        recipe.layers = [pasted, text, shape, Layer(name: "Contrast", content: .adjustment(.adjustments(adjust)))]
        let preview = try RenderPipeline.render(source, recipe: recipe, assets: store)
        let saved = try RenderPipeline.render(source, recipe: recipe, assets: store, final: true, flattenFor: .png)
        #expect(preview.width == saved.width && preview.height == saved.height)
        for (x, y) in [(5, 5), (230, 115), (60, 220), (300, 50), (390, 290)] {
            #expect(TestImages.pixel(preview, x: x, y: y) == TestImages.pixel(saved, x: x, y: y))
        }
        #expect(TestImages.pixel(saved, x: 300, y: 50).g < 30, "multiplied red")
    }
}

/// Set `FOLIO_PERF_LAYERS=1` to time a three-layer composite at 2048².
@Suite(.timeLimit(.minutes(1)), .enabled(if: Environment.perf)) struct LayerPerformanceTests {
    @Test func threeLayerCompositeIsFast() throws {
        let side = 2048.0
        let base = CIImage(cgImage: TestImages.cgImage(width: Int(side), height: Int(side)))
        var text = Layer(name: "Text", content: .text(TextSpec(runs: [TextRun(text: "Folio layers", size: 160, color: .white)])))
        text.transform = CGAffineTransform(translationX: 200, y: 300)
        var shape = Layer(
            name: "Shape",
            content: .shape(
                ShapeSpec(
                    geometry: .star(CGRect(x: 900, y: 900, width: 800, height: 800), points: 5, innerRadius: 0.45), fill: .solid(.red),
                    stroke: StrokeSpec(width: 12))))
        shape.blend = .overlay
        var a = Adjustments()
        a[.contrast] = 20
        let layers = [text, shape, Layer(name: "Contrast", content: .adjustment(.adjustments(a)))]
        let store = InMemoryAssetStore()
        func frame() throws {
            let image = LayerCompositor.composite(base: base, layers: layers, assets: store, scale: 1)
            _ = try RenderPipeline.rasterize(image, extent: base.extent, format: .RGBA8, colorSpace: sRGB)
        }
        try frame()  // compiles the kernels
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<5 { times.append(try clock.measure { try frame() }) }
        let median = times.sorted()[2]
        print("3-layer composite at 2048²: median \(median), all \(times)")
        #expect(median < .milliseconds(30))
    }
}

nonisolated private enum Environment {
    static var perf: Bool { ProcessInfo.processInfo.environment["FOLIO_PERF_LAYERS"] != nil }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct LayerCommandTests {
    let model: ImageEditorModel
    let undo = UndoManager()

    init() {
        model = ImageEditorModel(document: ImageDocument())
        undo.groupsByEvent = false
        model.undoManager = undo
    }

    var layers: [Layer] { model.document.recipe.layers }

    /// Run `command` as one user action, the way a menu item or button does.
    func step(_ command: () -> Void) {
        undo.beginUndoGrouping()
        command()
        undo.endUndoGrouping()
    }

    @Test func addAndDeleteAreOneStepEach() {
        step { model.addFillLayer() }
        step { model.addTextLayer("Hi") }
        step { model.addShapeLayer() }
        #expect(layers.map(\.name) == ["Fill", "Hi", "Shape"])
        #expect(model.selectedLayer?.name == "Shape")
        step { model.deleteSelectedLayer() }
        #expect(layers.map(\.name) == ["Fill", "Hi"])
        #expect(model.layerState.selectedID == layers[1].id, "selects the layer below")
        undo.undo()
        #expect(layers.count == 3)
        undo.undo()
        #expect(layers.count == 2)
    }

    @Test func addsAboveTheSelection() {
        step { model.addFillLayer() }
        step { model.addGradientLayer() }
        model.layerState.selectedID = layers[0].id
        step { model.addPaintLayer() }
        #expect(layers.map(\.name) == ["Fill", "Paint", "Gradient"])
        step { model.addAdjustmentLayer(.blur(radius: 3)) }
        #expect(layers[2].name == "Blur")
    }

    @Test func reorderDuplicateGroupUngroup() {
        for name in ["A", "B", "C"] { step { model.addTextLayer(name) } }
        step { model.moveLayers(fromOffsets: IndexSet(integer: 0), toOffset: 3) }
        #expect(layers.map(\.name) == ["B", "C", "A"])
        undo.undo()
        #expect(layers.map(\.name) == ["A", "B", "C"])
        model.layerState.selectedID = layers[1].id
        step { model.moveSelectedLayer(by: 1) }
        #expect(layers.map(\.name) == ["A", "C", "B"])
        step { model.duplicateSelectedLayer() }
        #expect(layers.map(\.name) == ["A", "C", "B", "B copy"])
        #expect(layers[2].id != layers[3].id)
        step { model.groupSelectedLayer() }
        guard case .group(let group) = layers[3].content else {
            Issue.record("not grouped")
            return
        }
        #expect(group.layers.map(\.name) == ["B copy"])
        step { model.setLayerOpacity(group.layers[0].id, 0.5) }
        #expect(layers[3].content != .group(group), "commands reach into groups")
        model.layerState.selectedID = layers[3].id
        step { model.ungroupSelectedLayer() }
        #expect(layers.map(\.name) == ["A", "C", "B", "B copy"])
        #expect(layers[3].opacity == 0.5)
    }

    @Test func lockedLayersOnlyToggleLockAndVisibility() {
        step { model.addShapeLayer() }
        let id = layers[0].id
        step { model.setLayerLocked(id, true) }
        step { model.transformLayer(id, by: CGAffineTransform(translationX: 10, y: 0)) }
        #expect(layers[0].transform == .identity)
        step { model.setLayerVisible(id, false) }
        #expect(!layers[0].isVisible)
        step { model.deleteSelectedLayer() }
        #expect(layers.count == 1)
        step { model.setLayerLocked(id, false) }
        step { model.setLayerBlend(id, .screen) }
        #expect(layers[0].blend == .screen)
    }

    @Test func liveEditsBecomeOneStep() {
        step { model.addShapeLayer() }
        let id = layers[0].id
        for x in 1...5 { model.transformLayer(id, by: CGAffineTransform(translationX: Double(x), y: 0), live: true) }
        step { model.endLive("Move") }
        #expect(layers[0].transform.tx == 15)
        undo.undo()
        #expect(layers[0].transform == .identity)
    }

    @Test func mergeDownMakesOnePixelLayer() throws {
        step { model.addFillLayer(RGBA(red: 0, green: 0, blue: 1)) }
        step { model.addShapeLayer(fill: .solid(.red)) }
        step { model.mergeDown() }
        #expect(layers.count == 1)
        guard case .pixels(let id) = layers[0].content else {
            Issue.record("not pixels")
            return
        }
        #expect(layers[0].name == "Fill")
        let size = model.source.pixelSize
        let out = composite(layers, base: solid(0, 1, 0, size: size), assets: model.document.assets)
        #expect(close(try pixel(out, x: Int(size.width / 2), y: Int(size.height / 2)), (255, 59, 48)))
        #expect(close(try pixel(out, x: 5, y: 5), (0, 0, 255)))
        #expect((try? model.document.assets.data(id)) != nil)
        undo.undo()
        #expect(layers.count == 2)
    }

    @Test func rasterizeAndFlatten() {
        step { model.addTextLayer("Pixels") }
        let before = LayerCompositor.bounds(of: layers[0], assets: model.document.assets)
        step { model.rasterizeSelectedLayer() }
        guard case .pixels = layers[0].content else {
            Issue.record("not rasterized")
            return
        }
        let after = LayerCompositor.bounds(of: layers[0], assets: model.document.assets)
        #expect(abs(after.minX - before.minX) <= 1 && abs(after.width - before.width) <= 2)
        step { model.addAdjustmentLayer(.blur(radius: 2)) }
        step { model.flattenImage() }
        #expect(layers.map(\.name) == ["Flattened"])
        undo.undo()
        #expect(layers.count == 2)
    }

    @Test func brushStrokesAppendAndBake() {
        let stroke = BrushStroke(points: [.init(location: CGPoint(x: 100, y: 100)), .init(location: CGPoint(x: 200, y: 120))])
        step { model.addBrushStroke(stroke) }
        #expect(layers.count == 1)
        for _ in 0..<49 { step { model.addBrushStroke(stroke) } }
        guard case .paint(let paint) = layers[0].content else {
            Issue.record("not paint")
            return
        }
        #expect(paint.strokes.isEmpty && paint.baked != nil, "baked after 50 strokes")
        undo.undo()
        guard case .paint(let undone) = layers[0].content else { return }
        #expect(undone.strokes.count == 49, "undoing the bake brings the strokes back")
    }

    @Test func imageLayersFitTheDocument() throws {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        try model.addImageLayer(TestImages.data(.png, width: 3200, height: 1000))
        let bounds = LayerCompositor.bounds(of: layers[0], assets: model.document.assets)
        #expect(abs(bounds.width - 1600) < 1 && bounds.minX >= -0.5)
        #expect(throws: (any Error).self) { try model.addImageLayer(TestImages.data(.png).prefix(10)) }
    }
}
