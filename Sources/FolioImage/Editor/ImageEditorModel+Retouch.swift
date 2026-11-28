import CoreGraphics
import CoreImage
import FolioKit
import Observation
import Vision

extension RetouchStroke.Tool: Identifiable {
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clone: "Clone"
        case .heal: "Heal"
        case .spotHeal: "Spot Heal"
        case .remove: "Remove"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .redact: "Redact"
        case .redEye: "Red-Eye"
        }
    }
    var symbol: String {
        switch self {
        case .clone: "seal"
        case .heal: "bandage"
        case .spotHeal: "circle.dotted"
        case .remove: "eraser.line.dashed"
        case .blur: "drop"
        case .pixelate: "squareshape.split.3x3"
        case .redact: "rectangle.fill"
        case .redEye: "eye"
        }
    }
    /// Clone and heal copy from an ⌥-clicked source point.
    var needsSource: Bool { self == .clone || self == .heal }
    /// Tools that can cover a dragged rectangle (⇧-drag) instead of a brushed path.
    var allowsRect: Bool { self == .blur || self == .pixelate || self == .redact }
}

/// The Retouch tool's options.
@Observable
final class RetouchState {
    var tool: RetouchStroke.Tool = .spotHeal
    /// Brush radius in screen points.
    var radius = 24.0
    var hardness = 0.5
    var opacity = 1.0
    var sampleAllLayers = true
    /// Clone and heal: the ⌥-clicked source, in source pixels.
    var sourcePoint: CGPoint?
}

extension ImageEditorModel {
    /// Add `stroke` to the retouch layer (creating it if needed), one undo step.
    ///
    /// Spot heal and remove are filled here, once, and the fill is stored as a `patch`
    /// asset, so re-renders, undo and saves never recompute it.
    func addRetouchStroke(_ stroke: RetouchStroke) {
        guard stroke.tool == .spotHeal || stroke.tool == .remove, stroke.patch == nil else {
            insertRetouchStrokes([stroke], actionName: stroke.tool.title)
            return
        }
        let source = self.source
        let recipe = document.recipe
        let assets = document.assets
        let index = retouchLayerIndex(in: recipe)
        let work = {
            do {
                var filled = stroke
                filled.patch = try await Self.computePatch(for: stroke, source: source, recipe: recipe, layerIndex: index, assets: assets)
                self.insertRetouchStrokes([filled], actionName: stroke.tool.title)
            } catch {
                self.show(error, title: "Couldn't \(stroke.tool == .remove ? "remove that" : "heal that spot")")
            }
        }
        // Remove can take a moment (texture synthesis); spot heal is instant.
        if stroke.tool == .remove { runBusy("Removing…", work) } else { Task { await work() } }
    }

    /// The current tool over the live selection.
    func retouchSelection() {
        guard let spec = selectionState.spec else { return }
        let state = retouchState
        addRetouchStroke(
            RetouchStroke(
                tool: state.tool, area: .selection(spec), hardness: state.hardness, opacity: state.opacity,
                sampleAllLayers: state.sampleAllLayers, amount: state.tool == .redEye ? 1 : 0))
    }

    /// Upscale the base image by `factor`, stored as a pixel asset.
    ///
    /// shortcut: the document's original can't be swapped from here (`ImageDocument.source`
    /// is fixed), so the upscaled edit is saved as a new PNG through Export; the
    /// integration step can turn it into a base-layer swap once the document supports one.
    func upscale(by factor: Double) {
        let source = self.source
        let recipe = document.recipe
        let assets = document.assets
        let label = factor == factor.rounded() ? "\(Int(factor))×" : "\(factor)×"
        Task {
            let url = await Exporter.save(suggestedName: "\(baseName) \(label)", type: .png) {
                try await Self.upscaledPNG(source: source, recipe: recipe, assets: assets, factor: factor)
            }
            if url != nil { showToast("Upscaled \(label) (\(SuperResolution.methodTitle))") }
        }
    }

    /// Redact every face, text block and/or barcode Vision finds.
    func autoRedact(faces: Bool, text: Bool, barcodes: Bool) {
        guard faces || text || barcodes else { return }
        let proxy = source.proxy
        let size = source.pixelSize
        runBusy("Looking for things to redact…") {
            do {
                let boxes = try await Self.redactionBoxes(in: proxy, faces: faces, text: text, barcodes: barcodes)
                guard !boxes.isEmpty else {
                    self.showToast("Nothing to redact found")
                    return
                }
                let strokes = boxes.map { unit in
                    RetouchStroke(
                        tool: .redact,
                        area: .rect(
                            CGRect(
                                x: unit.minX * size.width, y: unit.minY * size.height, width: unit.width * size.width,
                                height: unit.height * size.height)),
                        hardness: 1)
                }
                self.insertRetouchStrokes(strokes, actionName: "Redact")
                self.showToast("Redacted \(strokes.count) \(strokes.count == 1 ? "area" : "areas")")
            } catch {
                self.show(error, title: "Couldn't look for things to redact")
            }
        }
    }

    /// Find pupils with Vision and add a red-eye stroke over them.
    func fixRedEye() {
        let proxy = source.proxy
        let toSource = source.pixelSize.width / Double(proxy.width)
        runBusy("Finding eyes…") {
            do {
                let pupils = try await Self.detectPupils(in: proxy).map { CGPoint(x: $0.x * toSource, y: $0.y * toSource) }
                guard !pupils.isEmpty else {
                    self.showToast("No eyes found")
                    return
                }
                // Pupils come in pairs per face; a pupil is about a tenth of the gap between them.
                let gap = pupils.count >= 2 ? hypot(pupils[0].x - pupils[1].x, pupils[0].y - pupils[1].y) : self.source.pixelSize.width / 10
                let stroke = RetouchStroke(
                    tool: .redEye, area: .brush(points: pupils, radius: max(2, gap * 0.11)), hardness: 0.6, amount: 1)
                self.insertRetouchStrokes([stroke], actionName: "Fix Red-Eye")
            } catch {
                self.show(error, title: "Couldn't fix red-eye")
            }
        }
    }

    // MARK: Helpers

    /// The retouch layer strokes go to: the selected layer if it's one, else the top
    /// layer if it's one, else `nil` (a new layer on top).
    func retouchLayerIndex(in recipe: EditRecipe) -> Int? {
        func isRetouch(_ layer: Layer) -> Bool {
            if case .retouch = layer.content { !layer.isLocked } else { false }
        }
        if let id = layerState.selectedID, let i = recipe.layers.firstIndex(where: { $0.id == id }), isRetouch(recipe.layers[i]) {
            return i
        }
        if let last = recipe.layers.indices.last, isRetouch(recipe.layers[last]) { return last }
        return nil
    }

    private func insertRetouchStrokes(_ strokes: [RetouchStroke], actionName: String) {
        var selected = layerState.selectedID
        commit(actionName) { recipe in
            if let i = retouchLayerIndex(in: recipe), case .retouch(let existing) = recipe.layers[i].content {
                recipe.layers[i].content = .retouch(existing + strokes)
                selected = recipe.layers[i].id
            } else {
                let layer = Layer(name: "Retouch", content: .retouch(strokes))
                recipe.layers.append(layer)
                selected = layer.id
            }
        }
        layerState.selectedID = selected
    }

    /// Everything below the stroke at `scale`, as the compositor would hand it to
    /// ``RetouchRenderer``: the developed base, the layers under the retouch layer, and
    /// that layer's earlier strokes.
    nonisolated static func imageBelow(
        source: SourceImage, recipe: EditRecipe, layerIndex: Int?, assets: any AssetStore, scale: Double
    ) throws -> CIImage {
        let input = try RenderPipeline.input(for: source, raw: recipe.raw, scale: scale)
        let mask = recipe.removeBackground ? try source.subjectMask() : nil
        var image = RenderPipeline.filtered(input, recipe: recipe, assets: assets, scale: scale, mask: mask)
        let lower = layerIndex.map { Array(recipe.layers[..<$0]) } ?? recipe.layers
        if !lower.isEmpty { image = LayerCompositor.composite(base: image, layers: lower, assets: assets, scale: scale) }
        if let i = layerIndex, case .retouch(let strokes) = recipe.layers[i].content {
            image = RetouchRenderer.apply(strokes, to: image, assets: assets, scale: scale)
        }
        return image
    }

    /// The fill for a spot heal or remove stroke: the region around it, rendered,
    /// filled (push-pull for spot heal, PatchMatch for remove) and stored in `assets`.
    nonisolated static func computePatch(
        for stroke: RetouchStroke, source: SourceImage, recipe: EditRecipe, layerIndex: Int?, assets: any AssetStore
    ) async throws -> PlacedAsset {
        try await offCooperativePool {
            try patch(for: stroke, source: source, recipe: recipe, layerIndex: layerIndex, assets: assets)
        }
    }

    /// ``computePatch(for:source:recipe:layerIndex:assets:)``, blocking.
    nonisolated static func patch(
        for stroke: RetouchStroke, source: SourceImage, recipe: EditRecipe, layerIndex: Int?, assets: any AssetStore
    ) throws -> PlacedAsset {
        let full = CGRect(origin: .zero, size: source.pixelSize)
        let area = RetouchRenderer.bounds(of: stroke.area) ?? full
        let remove = stroke.tool == .remove
        // Context around the hole: PatchMatch needs texture to copy from.
        let margin = remove ? max(48, 0.75 * max(area.width, area.height)) : max(12, 0.5 * max(area.width, area.height))
        let region = area.insetBy(dx: -margin, dy: -margin).integral.intersection(full)
        guard !region.isNull, region.width >= 2, region.height >= 2 else { throw FolioError("That spot is outside the image.") }
        // PatchMatch runs on the CPU, so it works on a small proxy of the region. A
        // push-pull fill is smooth, so the screen proxy has all the detail it needs.
        let budget = remove ? 360.0 * 360 : 1536.0 * 1536
        let scale = min(remove ? 1 : source.proxyScale, (budget / (region.width * region.height)).squareRoot())

        let below = try imageBelow(source: source, recipe: recipe, layerIndex: layerIndex, assets: assets, scale: scale)
        let space = RetouchRenderer.Space(extent: below.extent, scale: scale)
        let rect = space.rect(region).integral.intersection(space.extent)
        var hard = stroke
        hard.hardness = 1
        hard.opacity = 1
        guard let area = RetouchRenderer.mask(for: hard, in: space, pixels: below) else { throw FolioError("That spot is empty.") }
        // A pixel of slack, so the soft edge of the brush blends into filled pixels.
        let toOrigin = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        let hole = area.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2]).cropped(to: rect).transformed(
            by: toOrigin)
        let crop = below.cropped(to: rect).transformed(by: toOrigin)
        let local = CGRect(origin: .zero, size: rect.size)
        let space8 = source.colorSpace
        var filled: CGImage?
        if remove {
            let pixels = try RenderPipeline.rasterize(crop, extent: local, format: .RGBA8, colorSpace: space8)
            let mask = try RenderPipeline.rasterize(hole.composited(over: CIImage.black), extent: local, format: .RGBA8, colorSpace: space8)
            filled = PatchMatch.fill(pixels, hole: mask)
        }
        if filled == nil {
            filled = try RenderPipeline.rasterize(PushPullFill.fill(crop, hole: hole), extent: local, format: .RGBA8, colorSpace: space8)
        }
        guard let filled else { throw RenderPipeline.RenderError() }
        let id = try assets.put(try ImageCodec.encode(filled, as: .png))
        // The region back in source pixels, from the pixel-aligned rectangle actually filled.
        let placed = CGRect(
            x: (rect.minX - space.extent.minX) / scale, y: (space.extent.maxY - rect.maxY) / scale,
            width: rect.width / scale, height: rect.height / scale)
        return PlacedAsset(asset: id, rect: placed)
    }

    nonisolated static func upscaledPNG(
        source: SourceImage, recipe: EditRecipe, assets: any AssetStore, factor: Double
    ) async throws -> Data {
        let rendered = try await offCooperativePool { try RenderPipeline.render(source, recipe: recipe, assets: assets, final: true) }
        let upscaled = try await SuperResolution.upscale(rendered, factor: factor)
        return try await offCooperativePool { try ImageCodec.encode(upscaled, as: .png) }
    }

    nonisolated static func detectPupils(in image: CGImage) async throws -> [CGPoint] {
        try await offCooperativePool { try RedEye.pupils(in: image) }
    }

    /// Faces, text and barcodes in `image`, as unit rectangles (top-left origin) padded
    /// a little so edges and descenders are covered.
    nonisolated static func redactionBoxes(in image: CGImage, faces: Bool, text: Bool, barcodes: Bool) async throws -> [CGRect] {
        try await offCooperativePool { try detectRedactionBoxes(in: image, faces: faces, text: text, barcodes: barcodes) }
    }

    private nonisolated static func detectRedactionBoxes(in image: CGImage, faces: Bool, text: Bool, barcodes: Bool) throws -> [CGRect] {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        let barcodeRequest = VNDetectBarcodesRequest()
        var requests: [VNRequest] = []
        if faces { requests.append(faceRequest) }
        if text { requests.append(textRequest) }
        if barcodes { requests.append(barcodeRequest) }
        do {
            try VNImageRequestHandler(cgImage: image).perform(requests)
        } catch {
            throw FolioError("Text and face detection aren't available on this Mac (\(error.localizedDescription)).")
        }
        func boxes(_ observations: [VNDetectedObjectObservation]?, pad: Double) -> [CGRect] {
            (observations ?? []).map { o in
                let b = o.boundingBox
                return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                    .insetBy(dx: -b.width * pad, dy: -b.height * pad)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
        return (faces ? boxes(faceRequest.results, pad: 0.15) : []) + (text ? boxes(textRequest.results, pad: 0.12) : [])
            + (barcodes ? boxes(barcodeRequest.results, pad: 0.06) : [])
    }
}
