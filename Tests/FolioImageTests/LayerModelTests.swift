import CoreGraphics
import CoreImage
import Testing
import UniformTypeIdentifiers

@testable import FolioImage

/// The 0.3 contract types: every enum case survives JSON, version 1 sessions still open,
/// and the new recipe fields change nothing until they're used.
@Suite(.timeLimit(.minutes(1))) struct LayerModelTests {
    private func roundTrips<T: Codable & Equatable>(_ value: T, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let decoded = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        #expect(decoded == value, sourceLocation: sourceLocation)
    }

    static let red = RGBA(red: 1, green: 0, blue: 0)
    static let box = CGRect(x: 10, y: 20, width: 300, height: 200)
    static let path = VectorPath(elements: [
        .move(to: CGPoint(x: 0, y: 0)), .line(to: CGPoint(x: 10, y: 0)),
        .quad(to: CGPoint(x: 10, y: 10), control: CGPoint(x: 15, y: 5)),
        .curve(to: CGPoint(x: 0, y: 10), control1: CGPoint(x: 8, y: 14), control2: CGPoint(x: 2, y: 14)), .close,
    ])
    static let gradient = GradientSpec(
        kind: .radial, stops: [ColorStop(location: 0, color: red), ColorStop(location: 1, color: .white)],
        start: CGPoint(x: 5, y: 5), end: CGPoint(x: 50, y: 60))

    static let selectionShapes: [SelectionSpec.Shape] = [
        .rect(box), .ellipse(box), .polygon([CGPoint(x: 1, y: 2), CGPoint(x: 30, y: 4), CGPoint(x: 9, y: 40)]), .path(path),
        .wand(seed: CGPoint(x: 4, y: 5), tolerance: 0.2, contiguous: false, sampleAllLayers: true),
        .colorRange(red, fuzziness: 0.4), .subject(instances: [1, 2]), .subject(instances: nil), .people(index: 0),
        .people(index: nil), .sky, .all, .pixels("abc123"),
    ]

    static var selection: SelectionSpec {
        var spec = SelectionSpec(
            ops: zip(selectionShapes, SelectionSpec.Mode.allCases.cycled(selectionShapes.count)).map {
                SelectionSpec.Op(shape: $0, mode: $1)
            })
        spec.feather = 2
        spec.expand = -3
        spec.smooth = 1
        spec.refineEdge = 4
        spec.inverted = true
        return spec
    }

    static var tone: ToneSpec {
        var tone = ToneSpec()
        tone.curves.rgb = [CGPoint(x: 0, y: 0.05), CGPoint(x: 0.5, y: 0.6), CGPoint(x: 1, y: 1)]
        tone.curves[.blue] = [CGPoint(x: 0.25, y: 0.2)]
        tone.levels.red = LevelsChannel(inputBlack: 0.05, inputWhite: 0.9, gamma: 1.2, outputBlack: 0, outputWhite: 1)
        for band in HueBand.allCases { tone.hsl[band] = HSLShift(hue: 5, saturation: -10, luminance: 3) }
        tone.colorBalance.shadows.cyanRed = -20
        tone.colorBalance.preserveLuminosity = false
        tone.channelMixer = ChannelMixer(red: .init(red: 0.4, green: 0.4, blue: 0.2), monochrome: true)
        tone.whiteBalance = WhiteBalance(temperature: 5200, tint: 12)
        tone.lut = LUTRef(asset: "cube", name: "Film", strength: 0.7)
        return tone
    }

    static let retouchStrokes: [RetouchStroke] = RetouchStroke.Tool.allCases.enumerated().map { index, tool in
        let areas: [RetouchStroke.Area] = [
            .brush(points: [CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 9)], radius: 12), .rect(box), .selection(SelectionSpec(.all)),
        ]
        return RetouchStroke(
            tool: tool, area: areas[index % areas.count], sourceOffset: CGSize(width: -40, height: 8), amount: 0.5,
            patch: PlacedAsset(asset: "patch", rect: box))
    }

    static var contents: [Layer.Content] {
        let text = TextSpec(
            runs: [TextRun(text: "Hello "), TextRun(text: "world", fontName: "Helvetica-Bold", size: 72, color: red, tracking: 50)],
            alignment: .center, lineHeight: 1.2, box: CGSize(width: 400, height: 120), path: path, fill: .gradient(gradient))
        let shape = ShapeSpec(
            geometry: .star(box, points: 5, innerRadius: 0.4), fill: .solid(red),
            stroke: StrokeSpec(color: .white, width: 3, dash: [4, 2], cap: .square, join: .bevel))
        let paint = PaintSpec(
            baked: PlacedAsset(asset: "baked", rect: box),
            strokes: [BrushStroke(points: [.init(location: CGPoint(x: 3, y: 4), pressure: 0.3)], size: 30, isEraser: true)])
        return [
            .pixels("0123abcd"), .text(text), .shape(shape), .fill(.gradient(gradient)), .adjustment(.blur(radius: 4)),
            .retouch(retouchStrokes), .paint(paint),
            .group(GroupSpec(layers: [Layer(name: "Inner", content: .fill(.solid(red)))], passThrough: false)),
        ]
    }

    @Test func everyLayerContentRoundTrips() throws {
        for content in Self.contents { try roundTrips(content) }
    }

    @Test func everyLayerPropertyRoundTrips() throws {
        let effects: [LayerEffect] = [
            .dropShadow(ShadowEffect(distance: 20, blur: 6)), .stroke(StrokeEffect(width: 5, position: .center)),
            .outerGlow(GlowEffect(radius: 30)),
        ]
        let masks: [MaskSource] = [.selection(Self.selection), .pixels("mask"), .vector(Self.path), .luminance(low: 0.2, high: 0.8)]
        for (index, blend) in Layer.BlendMode.allCases.enumerated() {
            var layer = Layer(name: blend.title, content: Self.contents[index % Self.contents.count])
            layer.blend = blend
            layer.opacity = 0.5
            layer.fillOpacity = 0.25
            layer.isVisible = index % 2 == 0
            layer.isLocked = index % 3 == 0
            layer.transform = CGAffineTransform(a: 0.9, b: 0.2, c: -0.2, d: 0.9, tx: 12, ty: -7)
            layer.perspective = Quad(
                topLeft: .zero, topRight: CGPoint(x: 100, y: 5), bottomRight: CGPoint(x: 95, y: 80), bottomLeft: CGPoint(x: 3, y: 90))
            layer.mask = LayerMask(source: masks[index % masks.count], feather: 3, density: 0.8, inverted: true, isEnabled: false)
            layer.clipsToBelow = true
            layer.effects = effects
            try roundTrips(layer)
        }
    }

    @Test func everyShapeAndAdjustmentRoundTrips() throws {
        let geometries: [ShapeSpec.Geometry] = [
            .rectangle(Self.box, cornerRadius: 8), .ellipse(Self.box),
            .line(from: .zero, to: CGPoint(x: 50, y: 50), startHead: .none, endHead: .closed), .polygon(Self.box, sides: 6),
            .star(Self.box, points: 7, innerRadius: 0.5), .speechBubble(Self.box, tail: CGPoint(x: 5, y: 300)), .path(Self.path),
        ]
        for geometry in geometries { try roundTrips(ShapeSpec(geometry: geometry)) }
        for head in ShapeSpec.ArrowHead.allCases {
            try roundTrips(ShapeSpec(geometry: .line(from: .zero, to: CGPoint(x: 1, y: 1), startHead: head, endHead: head)))
        }
        for kind in GradientSpec.Kind.allCases {
            var gradient = Self.gradient
            gradient.kind = kind
            try roundTrips(FillSpec.gradient(gradient))
        }
        var sliders = Adjustments()
        sliders[.exposure] = 20
        sliders[.vibrance] = -15
        let adjustments: [AdjustmentSpec] = [
            .adjustments(sliders), .tone(Self.tone), .filter(.noir, strength: 0.6), .blur(radius: 3), .pixelate(size: 16),
        ]
        for adjustment in adjustments { try roundTrips(adjustment) }
        for alignment in TextSpec.Alignment.allCases { try roundTrips(TextSpec(runs: [TextRun(text: "a")], alignment: alignment)) }
        for cap in StrokeSpec.Cap.allCases { try roundTrips(StrokeSpec(cap: cap)) }
        for join in StrokeSpec.Join.allCases { try roundTrips(StrokeSpec(join: join)) }
        for position in StrokeEffect.Position.allCases { try roundTrips(StrokeEffect(position: position)) }
    }

    @Test func selectionsAndToneRoundTrip() throws {
        for shape in Self.selectionShapes { try roundTrips(SelectionSpec(shape)) }
        try roundTrips(Self.selection)
        try roundTrips(Self.tone)
        for channel in ToneChannel.allCases { try roundTrips(channel) }
    }

    @Test func fullRecipeRoundTrips() throws {
        var recipe = EditRecipe()
        recipe.adjustments[.contrast] = 10
        recipe.tone = Self.tone
        recipe.layers = Self.contents.map { Layer(name: "Layer", content: $0) }
        recipe.guides = Guide.Axis.allCases.map { Guide(axis: $0, position: 120) }
        recipe.raw = RAWSettings(decoderVersion: "9", exposure: 0.5, temperature: 5600, highlightRecovery: true)
        recipe.perspective = Quad(
            topLeft: .zero, topRight: CGPoint(x: 1, y: 0), bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 1))
        for policy in HDRPolicy.allCases {
            recipe.hdr = policy
            try roundTrips(recipe)
        }
    }

    @Test func blendModesMatchPhotoshop() {
        #expect(Layer.BlendMode.allCases.count == 27)
        #expect(Set(Layer.BlendMode.allCases.map(\.title)).count == 27)
    }

    // MARK: Compatibility

    @Test func version1SessionStillRestores() throws {
        let store = EditSessionStore(root: URL.temporaryDirectory.appending(path: "folio-sessions-\(UUID().uuidString)"))
        let original = TestImages.data(.png)
        let output = TestImages.data(.jpeg)
        let originalKey = EditSessionStore.key(for: original)
        // Written by Folio 0.2 (EditRecipe version 1): no tone, layers, guides, raw, hdr.
        let json = """
            {"version":1,"originalKey":"\(originalKey)","originalType":"public.png","recipe":{
            "crop":[[0.1,0.2],[0.5,0.6]],"quarterTurns":1,"straighten":3.5,"flipHorizontal":true,"flipVertical":false,
            "resize":{"width":200,"height":150},"adjustments":{"values":["saturation",30,"exposure",-10]},
            "filter":"chrome","filterStrength":0.5,"removeBackground":false,
            "markup":[{"id":"6F1C8D1E-2B7A-4C55-9E0F-3A6B2D4C8E10","kind":"arrow","points":[[10,20],[30,40]],
            "color":{"red":1,"green":0.23,"blue":0.19,"alpha":1},"lineWidth":4,"text":"","fontSize":48}],
            "stripMetadata":false}}
            """
        try FileManager.default.createDirectory(at: store.root.appending(path: "sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.root.appending(path: "originals"), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.root.appending(path: "sessions/\(EditSessionStore.key(for: output)).json"))
        try original.write(to: store.root.appending(path: "originals/\(originalKey)"))

        let restored = try #require(store.restore(fileData: output))
        let recipe = restored.recipe
        #expect(restored.original == original)
        #expect(recipe.quarterTurns == 1 && recipe.flipHorizontal && recipe.straighten == 3.5)
        #expect(recipe.crop == CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        #expect(recipe.resize == PixelSize(width: 200, height: 150))
        #expect(recipe.adjustments[.saturation] == 30 && recipe.adjustments[.exposure] == -10)
        #expect(recipe.filter == .chrome && recipe.filterStrength == 0.5)
        #expect(recipe.markup.first?.kind == .arrow && recipe.markup.first?.points.last == CGPoint(x: 30, y: 40))
        #expect(recipe.tone.isIdentity && recipe.layers.isEmpty && recipe.guides.isEmpty)
        #expect(recipe.raw == nil && recipe.hdr == .keepIfPresent && recipe.perspective == nil)
        try roundTrips(recipe)
    }

    @Test func missingFieldsDecodeToDefaults() throws {
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: Data("{}".utf8))
        #expect(decoded == EditRecipe(), "every field has a default")
        #expect(EditRecipe.version == 2)
    }

    // MARK: Identity

    @Test func emptyStackIsIdentity() throws {
        var recipe = EditRecipe()
        recipe.tone.curves.rgb = [CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0)]
        recipe.tone.hsl[.aqua] = HSLShift()
        recipe.tone.channelMixer = ChannelMixer()
        recipe.tone.whiteBalance = WhiteBalance()
        recipe.tone.lut = LUTRef(asset: "x", name: "Off", strength: 0)
        recipe.normalize()
        #expect(recipe.isIdentity, "identity tone in any spelling normalizes away")
        recipe.tone.curves.rgb = [CGPoint(x: 0.5, y: 0.7)]
        recipe.normalize()
        #expect(!recipe.tone.isIdentity)
    }

    @Test func guidesAloneSaveTheOriginalBytes() throws {
        var recipe = EditRecipe()
        recipe.guides = [Guide(axis: .vertical, position: 40)]
        #expect(!recipe.changesPixels)
        let data = TestImages.data(.jpeg, metadata: true)
        #expect(try ImageSaver.data(for: SourceImage(data: data), recipe: recipe, as: .jpeg) == data)
    }

    @Test func emptyStackRendersLikeNoStack() throws {
        let source = try SourceImage(data: TestImages.data(.png))
        var plain = EditRecipe()
        plain.adjustments[.saturation] = 30
        var layered = plain
        layered.guides = [Guide(axis: .horizontal, position: 10)]
        layered.tone.curves.green = [CGPoint(x: 0.3, y: 0.3)]
        layered.normalize()
        let a = try ImageCodec.encode(RenderPipeline.render(source, recipe: plain, final: true), as: .png)
        let b = try ImageCodec.encode(RenderPipeline.render(source, recipe: layered, final: true), as: .png)
        #expect(a == b)
    }

    // MARK: Shared services

    @Test func assetsAreContentAddressed() throws {
        let store = InMemoryAssetStore()
        let blob = TestImages.data(.png)
        let id = store.put(blob)
        #expect(id == EditSessionStore.key(for: blob) && id.count == 64)
        #expect(store.put(blob) == id)
        #expect(try store.data(id) == blob)
        #expect(throws: (any Error).self) { try store.data("missing") }
    }

    @Test func metalKernelsCompileAtRunTime() throws {
        let source = """
            #include <CoreImage/CoreImage.h>
            using namespace metal;
            [[stitchable]] float4 folioInvert(coreimage::sample_t s) { return float4(s.a - s.rgb, s.a); }
            """
        let kernel = try #require(Kernels.kernel(named: "folioInvert", in: source) as? CIColorKernel)
        #expect(Kernels.kernel(named: "folioInvert", in: source) === kernel, "compiled once, then cached")
        #expect(Kernels.kernel(named: "nope", in: "not metal") == nil)
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let out = try #require(kernel.apply(extent: white.extent, arguments: [white]))
        let pixel = try TestImages.pixel(#require(RenderPipeline.context.createCGImage(out, from: white.extent)), x: 1, y: 1)
        #expect(pixel.r == 0 && pixel.g == 0 && pixel.b == 0 && pixel.a == 255)
    }
}

extension Collection {
    /// This collection repeated to `count` elements.
    fileprivate func cycled(_ count: Int) -> [Element] {
        (0..<count).map { self[index(startIndex, offsetBy: $0 % self.count)] }
    }
}
