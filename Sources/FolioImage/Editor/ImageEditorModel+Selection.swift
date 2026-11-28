import CoreGraphics
import CoreImage
import FolioKit
import Foundation
import Observation

/// The selection tools (the Select flyout in the tool rail).
enum SelectionTool: String, CaseIterable, Identifiable {
    case rectangle, ellipse, lasso, polygon, wand, colorRange, subject, sky
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .lasso: "Lasso"
        case .polygon: "Polygon Lasso"
        case .wand: "Magic Wand"
        case .colorRange: "Color Range"
        case .subject: "Select Subject"
        case .sky: "Select Sky"
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .ellipse: "circle.dashed"
        case .lasso: "lasso"
        case .polygon: "skew"
        case .wand: "wand.and.rays"
        case .colorRange: "eyedropper.halffull"
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        }
    }
}

/// A selection kept with "Save Selection": its mask is in the document's asset store.
struct SavedSelection: Identifiable, Equatable {
    var id: AssetID
    var name: String
}

/// The live selection and the selection tools' options. Not part of the recipe.
@Observable
final class SelectionState {
    var tool: SelectionTool = .rectangle
    /// How the next shape combines (⇧ add, ⌥ subtract, ⇧⌥ intersect).
    var mode: SelectionSpec.Mode = .add
    var spec: SelectionSpec?
    var wandTolerance = 0.15
    var contiguous = true
    var sampleAllLayers = true
    /// Color Range softness, 0…1.
    var fuzziness = 0.4
    /// "Save Selection", oldest first. In memory for this window.
    var saved: [SavedSelection] = []
}

extension ImageEditorModel {
    /// Combine `shape` into the live selection with `selectionState.mode`.
    func select(_ shape: SelectionSpec.Shape) { combine(shape) }

    /// Combine `shape` into the live selection with `mode` (default: the tool option), or
    /// replace the selection with it. One undo step.
    func combine(_ shape: SelectionSpec.Shape, mode: SelectionSpec.Mode? = nil, replacing: Bool = false) {
        let mode = mode ?? selectionState.mode
        guard !replacing, var base = selectionState.spec else {
            // Subtracting from or intersecting with nothing leaves nothing.
            if replacing || mode == .add { setSelection(SelectionSpec(shape), action: "Select") }
            return
        }
        // Inversion and refinement apply to the whole spec, so freeze them before adding.
        if base.inverted || base.feather != 0 || base.expand != 0 || base.smooth != 0 || base.refineEdge != 0 {
            guard let id = try? bake(base) else { return }
            base = SelectionSpec(.pixels(id))
        }
        setSelection(base.adding(shape, mode: mode), action: "Select")
    }

    func selectAll() { setSelection(SelectionSpec(.all), action: "Select All") }

    func deselect() { setSelection(nil, action: "Deselect") }

    func invertSelection() {
        guard var spec = selectionState.spec else { return }
        spec.inverted.toggle()
        setSelection(spec, action: "Select Inverse")
    }

    /// Grow (`pixels` > 0) or shrink the selection's edge, in source pixels.
    func growSelection(by pixels: Double) {
        guard var spec = selectionState.spec else { return }
        spec.expand += pixels
        setSelection(spec, action: pixels >= 0 ? "Expand Selection" : "Contract Selection")
    }

    func featherSelection(_ radius: Double) {
        guard var spec = selectionState.spec else { return }
        spec.feather = max(0, radius)
        setSelection(spec, action: "Feather Selection")
    }

    func smoothSelection(_ radius: Double) {
        guard var spec = selectionState.spec else { return }
        spec.smooth = max(0, radius)
        setSelection(spec, action: "Smooth Selection")
    }

    func refineSelectionEdge(_ radius: Double) {
        guard var spec = selectionState.spec else { return }
        spec.refineEdge = max(0, radius)
        setSelection(spec, action: "Refine Edge")
    }

    /// The subject under `point` (source pixels), or every subject when `nil`.
    func selectSubject(at point: CGPoint?) { selectSubject(at: point, mode: nil, replacing: false) }

    func selectSubject(at point: CGPoint?, mode: SelectionSpec.Mode?, replacing: Bool) {
        findThenSelect("Finding the subject…", mode: mode, replacing: replacing) { cg, factor in
            guard let point else { return .subject(instances: nil) }
            let label = try SubjectSelector.instance(at: CGPoint(x: point.x * factor, y: point.y * factor), in: cg)
            return label.map { .subject(instances: [$0]) }
        }
    }

    func selectSky(mode: SelectionSpec.Mode? = nil, replacing: Bool = false) {
        findThenSelect("Finding the sky…", mode: mode, replacing: replacing) { _, _ in .sky }
    }

    /// Every pixel like the one at `point` (source pixels), softly by `selectionState.fuzziness`.
    func selectColorRange(at point: CGPoint, mode: SelectionSpec.Mode? = nil, replacing: Bool = false) {
        let scale = source.proxyScale
        guard let pixels = try? Self.selectionPixels(source: source, recipe: recipe, assets: document.assets, scale: scale) else {
            return
        }
        var rgba = [UInt8](repeating: 0, count: 4)
        let height = (source.pixelSize.height * scale).rounded()
        let at = CGRect(x: (point.x * scale).rounded(.down), y: height - (point.y * scale).rounded(.down) - 1, width: 1, height: 1)
        RenderPipeline.context.render(
            pixels, toBitmap: &rgba, rowBytes: 4, bounds: at, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let color = RGBA(red: Double(rgba[0]) / 255, green: Double(rgba[1]) / 255, blue: Double(rgba[2]) / 255)
        combine(.colorRange(color, fuzziness: selectionState.fuzziness), mode: mode, replacing: replacing)
    }

    /// Copy the live selection into the selected layer's mask (one undo step).
    func addMaskFromSelection() {
        guard let spec = selectionState.spec else { return showToast("Make a selection first") }
        guard let layer = selectedLayer else { return showToast("Select a layer to mask") }
        updateLayer(layer.id, "Add Layer Mask") { $0.mask = LayerMask(source: .selection(spec)) }
    }

    /// Keep the live selection as a mask in the document, to load again later.
    func saveSelection(named name: String? = nil) {
        guard let spec = selectionState.spec else { return }
        do {
            let id = try bake(spec)
            selectionState.saved.append(SavedSelection(id: id, name: name ?? "Selection \(selectionState.saved.count + 1)"))
            showToast("Saved the selection")
        } catch {
            show(error, title: "Couldn't save the selection")
        }
    }

    func loadSelection(_ saved: SavedSelection, mode: SelectionSpec.Mode? = nil, replacing: Bool = true) {
        combine(.pixels(saved.id), mode: mode, replacing: replacing)
    }

    /// Set the live selection as one undo step (selection changes are undoable, as in
    /// Photoshop's history, though the selection isn't part of the recipe).
    func setSelection(_ spec: SelectionSpec?, action: String) {
        let old = selectionState.spec
        guard spec != old else { return }
        selectionState.spec = spec
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setSelection(old, action: action) }
        }
        undoManager?.setActionName(action)
    }

    // MARK: Rendering

    /// The live selection's mask at `scale` (see ``SelectionRenderer/mask(_:size:scale:pixels:assets:)``).
    func selectionMask(scale: Double) throws -> CIImage? {
        guard let spec = selectionState.spec else { return nil }
        return try Self.selectionMask(spec, source: source, recipe: recipe, assets: document.assets, scale: scale)
    }

    nonisolated static func selectionMask(
        _ spec: SelectionSpec, source: SourceImage, recipe: EditRecipe, assets: any AssetStore, scale: Double
    ) throws -> CIImage {
        let pixels = try needsPixels(spec) ? selectionPixels(source: source, recipe: recipe, assets: assets, scale: scale) : nil
        return try SelectionRenderer.mask(spec, size: source.pixelSize, scale: scale, pixels: pixels, assets: assets)
    }

    /// What the wand, color range, subject and sky analyse: the picture as edited (layers
    /// included), before geometry, so it lines up with source pixels.
    nonisolated static func selectionPixels(
        source: SourceImage, recipe: EditRecipe, assets: any AssetStore, scale: Double
    ) throws -> CIImage {
        let input = try RenderPipeline.input(for: source, raw: recipe.raw, scale: scale)
        let cutout = recipe.removeBackground ? try? source.subjectMask() : nil
        var image = RenderPipeline.filtered(input, recipe: recipe, assets: assets, scale: scale, mask: cutout)
        if !recipe.layers.isEmpty {
            image = LayerCompositor.composite(base: image, layers: recipe.layers, assets: assets, scale: scale)
        }
        return image
    }

    private nonisolated static func needsPixels(_ spec: SelectionSpec) -> Bool {
        spec.refineEdge > 0
            || spec.ops.contains {
                switch $0.shape {
                case .wand, .colorRange, .subject, .people, .sky: true
                case .rect, .ellipse, .polygon, .path, .all, .pixels: false
                }
            }
    }

    /// Render `spec` at proxy resolution into the asset store.
    // shortcut: proxy resolution (≤ 2048 px), so baked edges soften on big images; render at full size if that shows.
    private func bake(_ spec: SelectionSpec) throws -> AssetID {
        let mask = try Self.selectionMask(spec, source: source, recipe: recipe, assets: document.assets, scale: source.proxyScale)
        return try document.assets.put(SelectionRenderer.png(of: mask))
    }

    /// Run a Vision-backed `find` off the main actor on the analysis image, then select
    /// what it returns, or explain that nothing was found.
    private func findThenSelect(
        _ message: String, mode: SelectionSpec.Mode?, replacing: Bool,
        _ find: @escaping @Sendable (CGImage, Double) throws -> SelectionSpec.Shape?
    ) {
        let source = self.source, recipe = self.recipe, assets = document.assets
        runBusy(message) {
            switch await Self.find(source: source, recipe: recipe, assets: assets, find) {
            case .success(let shape?): self.combine(shape, mode: mode, replacing: replacing)
            case .success(nil): self.showToast("Nothing to select there")
            case .failure(let error): self.show(error, title: "Couldn't make the selection")
            }
        }
    }

    @concurrent
    private nonisolated static func find(
        source: SourceImage, recipe: EditRecipe, assets: any AssetStore,
        _ find: @Sendable (CGImage, Double) throws -> SelectionSpec.Shape?
    ) async -> Result<SelectionSpec.Shape?, any Error> {
        Result {
            let scale = source.proxyScale
            let pixels = try selectionPixels(source: source, recipe: recipe, assets: assets, scale: scale)
            let extent = CGRect(origin: .zero, size: CGSize(width: source.pixelSize.width * scale, height: source.pixelSize.height * scale))
            guard let cg = SelectionRenderer.analysisImage(pixels, extent: extent) else { return nil }
            guard let shape = try find(cg, scale * Double(cg.width) / max(1, extent.width)) else { return nil }
            // Analyse now (cached), so the marching ants appear at once and "nothing found" shows here.
            return try SubjectSelector.mask(shape, in: cg) == nil ? nil : shape
        }
    }
}
