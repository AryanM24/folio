import CoreGraphics
import CoreImage
import FolioKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Which layer the Layers panel, the Layer inspector and the transform handles act on.
@Observable
final class LayerEditingState {
    var selectedID: UUID?
}

// Each command is one undo step through `commit(_:_:)`. Commands find layers at any
// depth, so they work inside groups too.
extension ImageEditorModel {
    var selectedLayer: Layer? { layerState.selectedID.flatMap { recipe.layers.layer($0) } }

    /// Insert above the selected layer (or on top) and select it.
    func addLayer(_ layer: Layer) {
        commit("Add Layer") { recipe in
            if let id = layerState.selectedID, recipe.layers.withParent(of: id, { $0.insert(layer, at: $1 + 1) }) { return }
            recipe.layers.append(layer)
        }
        layerState.selectedID = layer.id
    }

    // MARK: New layers

    private var documentRect: CGRect { CGRect(origin: .zero, size: source.pixelSize) }

    /// A pasted or imported image, centered and shrunk to fit the document if needed.
    func addImageLayer(_ data: Data, name: String = "Image") throws {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]), !image.extent.isEmpty else {
            throw FolioError("Folio couldn't read that image.")
        }
        let id = try document.assets.put(data)
        let size = image.extent.size, doc = documentRect.size
        let fit = min(1, doc.width / size.width, doc.height / size.height)
        var layer = Layer(name: name, content: .pixels(id))
        layer.transform = CGAffineTransform(scaleX: fit, y: fit)
            .concatenating(CGAffineTransform(translationX: (doc.width - size.width * fit) / 2, y: (doc.height - size.height * fit) / 2))
        addLayer(layer)
    }

    func addTextLayer(_ string: String = "Text") {
        let doc = documentRect.size
        let text = TextSpec(runs: [TextRun(text: string, size: max(12, (min(doc.width, doc.height) / 10).rounded()))])
        let size = TextRenderer.size(of: text)
        var layer = Layer(name: string, content: .text(text))
        layer.transform = CGAffineTransform(translationX: (doc.width - size.width) / 2, y: (doc.height - size.height) / 2)
        addLayer(layer)
    }

    /// A shape; without `geometry`, a rectangle a quarter of the document, centered.
    func addShapeLayer(_ geometry: ShapeSpec.Geometry? = nil, fill: FillSpec? = .solid(RGBA(red: 0.2, green: 0.45, blue: 0.9))) {
        let doc = documentRect
        let box = doc.insetBy(dx: doc.width * 3 / 8, dy: doc.height * 3 / 8)
        addLayer(Layer(name: "Shape", content: .shape(ShapeSpec(geometry: geometry ?? .rectangle(box, cornerRadius: 0), fill: fill))))
    }

    func addFillLayer(_ color: RGBA = .white) {
        addLayer(Layer(name: "Fill", content: .fill(.solid(color))))
    }

    /// A gradient; without `spec`, black to white top to bottom.
    func addGradientLayer(_ spec: GradientSpec? = nil) {
        let doc = documentRect
        let spec =
            spec
            ?? GradientSpec(
                stops: [ColorStop(location: 0, color: RGBA(red: 0, green: 0, blue: 0)), ColorStop(location: 1, color: .white)],
                start: CGPoint(x: doc.midX, y: 0), end: CGPoint(x: doc.midX, y: doc.maxY))
        addLayer(Layer(name: "Gradient", content: .fill(.gradient(spec))))
    }

    func addAdjustmentLayer(_ spec: AdjustmentSpec) {
        let name =
            switch spec {
            case .adjustments: "Adjustments"
            case .tone: "Tone"
            case .filter(let preset, _): preset.title
            case .blur: "Blur"
            case .pixelate: "Pixelate"
            }
        addLayer(Layer(name: name, content: .adjustment(spec)))
    }

    func addPaintLayer() {
        addLayer(Layer(name: "Paint", content: .paint(PaintSpec())))
    }

    /// Append a brush stroke to the selected paint layer (a new paint layer when the
    /// selection isn't one). One stroke is one undo step; every 50 strokes the layer is
    /// baked into pixels in the same step, so the recipe stays small.
    func addBrushStroke(_ stroke: BrushStroke) {
        guard let layer = selectedLayer, case .paint(var paint) = layer.content else {
            if !stroke.isEraser { addLayer(Layer(name: "Paint", content: .paint(PaintSpec(strokes: [stroke])))) }
            return
        }
        paint.strokes.append(stroke)
        if paint.strokes.count >= 50, let baked = bake(paint) { paint = PaintSpec(baked: baked) }
        updateLayer(layer.id, stroke.isEraser ? "Erase" : "Brush Stroke") { $0.content = .paint(paint) }
    }

    // MARK: Layer properties

    /// Change the layer with `id`; `live` turns a drag into one step (see `live(_:)`).
    /// Locked layers only change their lock and visibility.
    func updateLayer(_ id: UUID, _ actionName: String, live isLive: Bool = false, _ change: (inout Layer) -> Void) {
        let apply: (inout EditRecipe) -> Void = { recipe in
            recipe.layers.withParent(of: id) { list, index in
                let old = list[index]
                var new = old
                change(&new)
                var rest = new
                rest.isLocked = old.isLocked
                rest.isVisible = old.isVisible
                guard !old.isLocked || rest == old else { return }
                list[index] = new
            }
        }
        if isLive { live(apply) } else { commit(actionName, apply) }
    }

    func setLayerVisible(_ id: UUID, _ visible: Bool) {
        updateLayer(id, visible ? "Show Layer" : "Hide Layer") { $0.isVisible = visible }
    }

    func setLayerLocked(_ id: UUID, _ locked: Bool) {
        updateLayer(id, locked ? "Lock Layer" : "Unlock Layer") { $0.isLocked = locked }
    }

    func setLayerOpacity(_ id: UUID, _ opacity: Double, live: Bool = false) {
        updateLayer(id, "Layer Opacity", live: live) { $0.opacity = min(1, max(0, opacity)) }
    }

    func setLayerBlend(_ id: UUID, _ blend: Layer.BlendMode) {
        updateLayer(id, "Blend Mode") { $0.blend = blend }
    }

    /// Move, scale or rotate: `transform` (source pixels) is applied after the layer's own.
    func transformLayer(_ id: UUID, by transform: CGAffineTransform, live: Bool = false) {
        updateLayer(id, "Transform Layer", live: live) { $0.transform = $0.transform.concatenating(transform) }
    }

    // MARK: Arranging

    func deleteSelectedLayer() {
        guard let id = layerState.selectedID, let layer = selectedLayer, !layer.isLocked else { return }
        var next: UUID?
        commit("Delete Layer") { recipe in
            recipe.layers.withParent(of: id) { list, index in
                list.remove(at: index)
                next = list.isEmpty ? nil : list[max(0, index - 1)].id
            }
        }
        layerState.selectedID = next
    }

    /// Reorder top-level layers (`List.onMove` offsets, bottom → top order).
    func moveLayers(fromOffsets source: IndexSet, toOffset destination: Int) {
        commit("Move Layer") { recipe in
            let moving = source.filter { recipe.layers.indices.contains($0) }.map { recipe.layers[$0] }
            var rest = recipe.layers.enumerated().filter { !source.contains($0.offset) }.map(\.element)
            let at = destination - source.filter { $0 < destination }.count
            rest.insert(contentsOf: moving, at: min(max(0, at), rest.count))
            recipe.layers = rest
        }
    }

    /// Bring the selected layer forward (+1) or send it backward (−1) within its group.
    func moveSelectedLayer(by delta: Int) {
        guard let id = layerState.selectedID else { return }
        commit(delta > 0 ? "Bring Forward" : "Send Backward") { recipe in
            recipe.layers.withParent(of: id) { list, index in
                let target = min(max(0, index + delta), list.count - 1)
                list.insert(list.remove(at: index), at: target)
            }
        }
    }

    func duplicateSelectedLayer() {
        guard let id = layerState.selectedID, let layer = selectedLayer else { return }
        var copy = layer.withNewIDs()
        copy.name = "\(layer.name) copy"
        copy.isLocked = false
        commit("Duplicate Layer") { recipe in recipe.layers.withParent(of: id) { $0.insert(copy, at: $1 + 1) } }
        layerState.selectedID = copy.id
    }

    func groupSelectedLayer() {
        guard let id = layerState.selectedID, let layer = selectedLayer else { return }
        let group = Layer(name: "Group", content: .group(GroupSpec(layers: [layer])))
        commit("Group Layer") { recipe in recipe.layers.withParent(of: id) { $0[$1] = group } }
        layerState.selectedID = group.id
    }

    /// Replace the selected group by its children, keeping where they appear.
    func ungroupSelectedLayer() {
        guard let id = layerState.selectedID, let layer = selectedLayer, case .group(let group) = layer.content else { return }
        let children = group.layers.map { child in
            var child = child
            child.transform = child.transform.concatenating(layer.transform)
            return child
        }
        commit("Ungroup") { recipe in
            recipe.layers.withParent(of: id) { list, index in list.replaceSubrange(index...index, with: children) }
        }
        layerState.selectedID = children.last?.id
    }

    /// Merge the selected layer into the one below it. The result keeps the lower
    /// layer's name, opacity and blend mode, like Photoshop.
    func mergeDown() {
        guard let id = layerState.selectedID, let upper = selectedLayer, !upper.isLocked else { return }
        var pair: (Layer, Layer)?
        var copy = recipe.layers
        copy.withParent(of: id) { list, index in if index > 0 { pair = (list[index - 1], list[index]) } }
        guard let (lower, _) = pair, !lower.isLocked else { return }
        var flat = lower
        flat.opacity = 1
        flat.blend = .normal
        let rects = [lower, upper].map(bounds)
        // A fill or adjustment (null bounds) covers the whole document.
        let rect = rects.contains(where: \.isNull) ? documentRect : rects[0].union(rects[1])
        guard let (asset, placed) = bake([flat, upper], in: rect) else { return }
        var merged = Layer(name: lower.name, content: .pixels(asset))
        merged.transform = CGAffineTransform(translationX: placed.minX, y: placed.minY)
        merged.opacity = lower.opacity
        merged.blend = lower.blend
        merged.clipsToBelow = lower.clipsToBelow
        commit("Merge Down") { recipe in
            recipe.layers.withParent(of: id) { list, index in list.replaceSubrange(index - 1...index, with: [merged]) }
        }
        layerState.selectedID = merged.id
    }

    /// Every layer and the base image become one opaque pixel layer.
    func flattenImage() {
        guard !recipe.layers.isEmpty, let input = try? RenderPipeline.input(for: source, raw: recipe.raw, scale: 1) else { return }
        let mask = recipe.removeBackground ? try? source.subjectMask() : nil
        let base = RenderPipeline.filtered(input, recipe: recipe, assets: document.assets, scale: 1, mask: mask)
        guard let (asset, _) = bake(recipe.layers, over: base, in: documentRect) else { return }
        let flat = Layer(name: "Flattened", content: .pixels(asset))
        commit("Flatten Image") { $0.layers = [flat] }
        layerState.selectedID = flat.id
    }

    /// Turn the selected text, shape, fill, paint or group layer into pixels. Masks drawn
    /// in the layer's space are baked in; selection and luminosity masks stay live.
    func rasterizeSelectedLayer() {
        guard let layer = selectedLayer, !layer.isLocked, !layer.coversDocument else { return }
        if case .pixels = layer.content, layer.perspective == nil, layer.transform.isTranslationOnly { return }
        var flat = layer
        flat.opacity = 1
        flat.fillOpacity = 1
        flat.blend = .normal
        flat.effects = []
        flat.clipsToBelow = false
        flat.isVisible = true
        var keptMask: LayerMask?
        switch layer.mask?.source {
        case .selection, .luminance:
            keptMask = layer.mask
            flat.mask = nil
        default: break
        }
        let rect = bounds(flat)
        guard let (asset, placed) = bake([flat], in: rect.isNull ? documentRect : rect) else { return }
        updateLayer(layer.id, "Rasterize Layer") {
            $0.content = .pixels(asset)
            $0.transform = CGAffineTransform(translationX: placed.minX, y: placed.minY)
            $0.perspective = nil
            $0.mask = keptMask
        }
    }

    // MARK: Baking pixels

    private func bounds(_ layer: Layer) -> CGRect { LayerCompositor.bounds(of: layer, assets: document.assets) }

    /// `layers` over `base` (transparency when `nil`) at full size, cut to `rect` (source
    /// pixels, clipped to the document) and stored as a PNG asset. Returns the asset and
    /// the rectangle it covers.
    // shortcut: renders on the main actor; fine for one layer, slow for flattening 100 MP+.
    private func bake(_ layers: [Layer], over base: CIImage? = nil, in rect: CGRect) -> (AssetID, CGRect)? {
        let doc = documentRect
        let area = rect.intersection(doc).integral
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let backdrop = (base ?? CIImage(color: .clear)).cropped(to: doc)
        let image = LayerCompositor.composite(base: backdrop, layers: layers, assets: document.assets, scale: 1)
        let extent = CGRect(x: area.minX, y: doc.height - area.maxY, width: area.width, height: area.height)
        let format: CIFormat = source.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let cg = try? RenderPipeline.rasterize(image, extent: extent, format: format, colorSpace: source.colorSpace),
            let data = try? ImageCodec.encode(cg, as: .png), let id = try? document.assets.put(data)
        else { return nil }
        return (id, area)
    }

    /// The paint layer's strokes and baked raster as one new raster, in layer space.
    private func bake(_ paint: PaintSpec) -> PlacedAsset? {
        guard let image = PaintRenderer.image(paint, assets: document.assets, scale: 1), let space = CGColorSpace(name: CGColorSpace.sRGB),
            let cg = try? RenderPipeline.rasterize(image, extent: image.extent, format: .RGBA8, colorSpace: space),
            let data = try? ImageCodec.encode(cg, as: .png), let id = try? document.assets.put(data)
        else { return nil }
        let e = image.extent
        return PlacedAsset(asset: id, rect: CGRect(x: e.minX, y: -e.maxY, width: e.width, height: e.height))
    }
}

// MARK: - Finding layers in the tree

nonisolated extension [Layer] {
    /// The layer with `id`, at any depth.
    func layer(_ id: UUID) -> Layer? {
        for layer in self {
            if layer.id == id { return layer }
            if case .group(let group) = layer.content, let hit = group.layers.layer(id) { return hit }
        }
        return nil
    }

    /// Runs `body` on the array that holds `id` (at any depth) with its index there.
    /// Returns false when no layer has that ID.
    @discardableResult
    mutating func withParent(of id: UUID, _ body: (inout [Layer], Int) -> Void) -> Bool {
        if let index = firstIndex(where: { $0.id == id }) {
            body(&self, index)
            return true
        }
        for index in indices {
            guard case .group(var group) = self[index].content else { continue }
            if group.layers.withParent(of: id, body) {
                self[index].content = .group(group)
                return true
            }
        }
        return false
    }
}

nonisolated extension Layer {
    /// A copy whose ID, and every child's, is new.
    func withNewIDs() -> Layer {
        var copy = self
        copy.id = UUID()
        if case .group(var group) = content {
            group.layers = group.layers.map { $0.withNewIDs() }
            copy.content = .group(group)
        }
        return copy
    }
}

nonisolated extension CGAffineTransform {
    var isTranslationOnly: Bool { a == 1 && b == 0 && c == 0 && d == 1 }
}
