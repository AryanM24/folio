import AppKit
import Combine
import CoreImage
import FolioKit
import SwiftUI

private let log = Log.make("Image")

/// The inspector's tabs. The first four make the tab strip; Crop shows while the crop
/// tool is active, and Markup edits 0.2 markup items (Image menu).
enum InspectorTab: String, CaseIterable, Identifiable {
    case adjust, tone, filters, layer, crop, markup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adjust: "Adjust"
        case .tone: "Tone"
        case .filters: "Filters"
        case .layer: "Layer"
        case .crop: "Crop"
        case .markup: "Markup"
        }
    }
    static let strip: [InspectorTab] = [.adjust, .tone, .filters, .layer]
}

/// Options for the brush, eraser, text, shape, gradient and zoom tools.
struct ToolOptions: Equatable {
    /// Brush, text, shape and gradient color; the eyedropper sets it.
    var color = RGBA(red: 0.12, green: 0.39, blue: 0.68)
    /// Brush and eraser diameter in screen points.
    var brushSize = 24.0
    var hardness = 0.8
    var opacity = 1.0
    var shape: ShapeKind = .rectangle
    var gradient: GradientSpec.Kind = .linear
    /// Text size in screen points at the current zoom.
    var fontSize = 32.0
    /// Zoom tool clicks zoom out (⌥ flips it).
    var zoomOut = false
}

/// What the Shape tool draws.
enum ShapeKind: String, CaseIterable, Identifiable {
    case rectangle, ellipse, line, arrow, polygon, star, bubble
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .polygon: "Polygon"
        case .star: "Star"
        case .bubble: "Speech bubble"
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .polygon: "hexagon"
        case .star: "star"
        case .bubble: "bubble.left"
        }
    }

    /// The shape filling `rect` (source pixels), dragged from `start` to `end`.
    func geometry(from start: CGPoint, to end: CGPoint) -> ShapeSpec.Geometry {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch self {
        case .rectangle: return .rectangle(rect, cornerRadius: 0)
        case .ellipse: return .ellipse(rect)
        case .line: return .line(from: start, to: end, startHead: .none, endHead: .none)
        case .arrow: return .line(from: start, to: end, startHead: .none, endHead: .closed)
        case .polygon: return .polygon(rect, sides: 6)
        case .star: return .star(rect, points: 5, innerRadius: 0.45)
        case .bubble: return .speechBubble(rect, tail: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY + rect.height * 0.25))
        }
    }
}

/// The pixel under the pointer, for the status bar.
struct CanvasCursor: Equatable {
    /// Source pixels.
    var point: CGPoint
    var color: RGBA?
}

/// One frame of the canvas: the edit as a Core Image graph (y up, origin zero), not yet
/// rendered. `@unchecked Sendable`: `CIImage` is immutable.
nonisolated struct CanvasFrame: @unchecked Sendable {
    let image: CIImage
    let extent: CGRect
}

/// Everything below the selected layer as a cached intermediate, and what it was made of.
nonisolated struct BelowLayers: @unchecked Sendable {
    let key: EditRecipe
    let scale: Double
    let image: CIImage
}

/// Toolbar popovers that menu commands can open.
enum EditorPopover { case info, export }

/// Markup tools. `select` picks and moves existing items.
enum MarkupTool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, arrow, rectangle, ellipse, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: "Select"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        }
    }
    var kind: MarkupItem.Kind? { MarkupItem.Kind(rawValue: rawValue) }
}

/// Everything the editor window shows that isn't saved: zoom, the current tab and
/// tool, the rendered preview. Edits go to ``ImageDocument`` through ``commit(_:_:)``
/// (one undo step) or ``live(_:)`` + ``endLive(_:)`` (a drag that becomes one step).
@Observable
final class ImageEditorModel {
    let document: ImageDocument
    var undoManager: UndoManager?
    /// For export names.
    var fileURL: URL?

    /// The recipe on screen: the document's, or a drag in progress.
    private(set) var recipe: EditRecipe
    /// The committed recipe when a live drag began.
    private var liveBase: EditRecipe?

    var tab: InspectorTab = .adjust { didSet { if tab != oldValue { tabChanged(from: oldValue) } } }
    /// The strip tab to go back to when Crop or Markup closes.
    @ObservationIgnored private var stripTab: InspectorTab = .adjust

    // Canvas
    /// Points per output pixel, or `nil` to fit the window.
    var zoom: Double? { didSet { requestRender() } }
    /// The display pixel at the middle of the canvas, or `nil` for the picture's middle.
    var center: CGPoint?
    var viewportSize: CGSize = .zero { didSet { if viewportSize != oldValue { requestRender() } } }
    var backingScale: Double = 2
    /// What the canvas draws: the edit's graph, rendered on the GPU for the visible area.
    private(set) var frame: CanvasFrame?
    /// A proxy-sized bitmap of the edit for the histogram, Live Text and the color under
    /// the pointer. Follows `frame` after a short pause.
    private(set) var preview: CGImage?
    /// Hold-to-compare: show the untouched original.
    var comparing = false
    /// The pixel under the pointer; `nil` off the picture.
    var cursor: CanvasCursor?
    var showRulers = false
    var showGuides = true
    var snapToGuides = true
    var showPixelGrid = true
    /// Space is held: drags pan, whatever the tool.
    var spacePanning = false

    // Markup
    var markupTool: MarkupTool = .pen
    var markupColor: RGBA = .red
    /// Stroke width in screen points at the current zoom.
    var markupWidth = 4.0
    var selectedMarkupID: UUID?
    /// The item being drawn; not in the recipe until the drag ends.
    var draftMarkup: MarkupItem?
    /// Ask the inspector to focus the text field (after placing text).
    var focusMarkupText = false
    /// A text field in the inspector has focus, so single-key shortcuts stand down.
    var isEditingText = false
    /// A popover a menu command asked the toolbar to open.
    var requestedPopover: EditorPopover?

    // Crop
    var cropAspect: CropAspect = .free

    // 0.3 tools. Each work package keeps its editing state in its own class (extensions
    // can't add stored properties), declared next to its commands.
    var tool: ImageTool = .move { didSet { if tool != oldValue { toolChanged(from: oldValue) } } }
    var options = ToolOptions()
    let layerState = LayerEditingState()
    let selectionState = SelectionState()
    let retouchState = RetouchState()

    // Smart features
    var liveTextEnabled = false
    private(set) var filterThumbnails: [FilterPreset: CGImage] = [:]
    private(set) var filterBase: CGImage?
    /// A short status message ("Copied #1E63AE").
    private(set) var toast: String?
    private(set) var busyMessage: String?

    @ObservationIgnored private var cancellable: AnyCancellable?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRender: RenderRequest?
    @ObservationIgnored private var lastRender: RenderRequest?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// Layers below the selected one, cached so dragging it re-renders only it and above.
    @ObservationIgnored private var belowCache: BelowLayers?

    init(document: ImageDocument) {
        self.document = document
        recipe = document.recipe
        // Undo, redo and menu commands change the document directly; follow along.
        cancellable = document.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.documentChanged() }
        requestRender()
    }

    var source: SourceImage { document.source }
    var geometry: ImageGeometry { ImageGeometry(sourceSize: source.pixelSize, recipe: recipe) }
    var isEdited: Bool { !document.recipe.isIdentity }
    var canSaveInPlace: Bool { ImageCodec.canWrite(source.type) }

    private func documentChanged() {
        guard liveBase == nil, recipe != document.recipe else { return }
        recipe = document.recipe
        if let id = selectedMarkupID, !recipe.markup.contains(where: { $0.id == id }) { selectedMarkupID = nil }
        requestRender()
        refreshThumbnailsIfVisible()
    }

    // MARK: Editing

    /// Apply `change` as one undoable step.
    func commit(_ actionName: String, _ change: (inout EditRecipe) -> Void) {
        var new = liveBase ?? document.recipe
        if liveBase != nil { new = recipe; liveBase = nil }
        change(&new)
        new.normalize()
        recipe = new
        document.setRecipe(new, actionName: actionName, undoManager: undoManager)
        requestRender()
        refreshThumbnailsIfVisible()
    }

    /// Change the on-screen recipe during a drag without touching undo.
    func live(_ change: (inout EditRecipe) -> Void) {
        if liveBase == nil { liveBase = document.recipe }
        var new = recipe
        change(&new)
        new.normalize()
        guard new != recipe else { return }
        recipe = new
        requestRender()
    }

    /// Finish a drag: the whole gesture becomes one undo step.
    func endLive(_ actionName: String) {
        guard liveBase != nil else { return }
        let final = recipe
        liveBase = nil
        document.setRecipe(final, actionName: actionName, undoManager: undoManager)
        refreshThumbnailsIfVisible()
    }

    var isLiveEditing: Bool { liveBase != nil }

    /// A slider binding that coalesces a drag into one undo step.
    func binding(_ keyPath: WritableKeyPath<EditRecipe, Double>, action: String) -> Binding<Double> {
        Binding(
            get: { self.recipe[keyPath: keyPath] },
            set: { value in
                if self.isLiveEditing {
                    self.live { $0[keyPath: keyPath] = value }
                } else {
                    self.commit(action) { $0[keyPath: keyPath] = value }
                }
            }
        )
    }

    func sliderEditing(_ editing: Bool, action: String) {
        if editing {
            if liveBase == nil { liveBase = document.recipe }
        } else {
            endLive(action)
        }
    }

    // MARK: Commands

    func rotateLeft() { commit("Rotate Left") { $0.rotateCounterclockwise() } }
    func rotateRight() { commit("Rotate Right") { $0.rotateClockwise() } }
    func flipHorizontal() { commit("Flip Horizontal") { $0.flipHorizontallyOnScreen() } }
    func flipVertical() { commit("Flip Vertical") { $0.flipVerticallyOnScreen() } }
    func resetAll() { commit("Reset All") { $0 = EditRecipe() } }
    func resetAdjustments() {
        commit("Reset Adjustments") {
            $0.adjustments = Adjustments(); $0.autoEnhance = nil
        }
    }
    func resetCrop() {
        cropAspect = .free
        commit("Reset Crop") {
            $0.crop = EditRecipe.fullCrop; $0.straighten = 0; $0.quarterTurns = 0; $0.flipHorizontal = false; $0.flipVertical = false;
            $0.resize = nil
        }
    }

    func setAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let ratio = aspect.ratio(original: geometry.canvasSize) else { return }
        commit("Crop Aspect") {
            $0.crop = CropMath.fit(
                ratio: ratio, canvas: ImageGeometry(sourceSize: source.pixelSize, recipe: $0).canvasSize, around: $0.crop)
            $0.resize = nil
        }
    }

    func toggleAutoEnhance() {
        if recipe.autoEnhance != nil {
            commit("Auto-Enhance") { $0.autoEnhance = nil }
            return
        }
        let source = self.source
        runBusy("Enhancing…") {
            guard let specs = try? await offCooperativePool({ RenderPipeline.autoEnhance(for: source.proxyImage) }) else { return }
            self.commit("Auto-Enhance") { $0.autoEnhance = specs }
        }
    }

    func toggleRemoveBackground() {
        if recipe.removeBackground {
            commit("Restore Background") { $0.removeBackground = false }
            return
        }
        let source = self.source
        runBusy("Finding the subject…") {
            do {
                _ = try await offCooperativePool { try source.subjectMask() }
                self.commit("Remove Background") { $0.removeBackground = true }
            } catch {
                self.show(error, title: "Couldn't remove the background")
            }
        }
    }

    func toggleStripMetadata() {
        commit(recipe.stripMetadata ? "Keep Metadata" : "Remove Metadata") { $0.stripMetadata.toggle() }
    }

    // MARK: Markup

    var selectedMarkup: MarkupItem? {
        guard let id = selectedMarkupID else { return nil }
        return recipe.markup.first { $0.id == id }
    }

    func updateSelectedMarkup(_ action: String, live isLive: Bool = false, _ change: (inout MarkupItem) -> Void) {
        guard let id = selectedMarkupID, let index = recipe.markup.firstIndex(where: { $0.id == id }) else { return }
        let apply: (inout EditRecipe) -> Void = { recipe in
            guard index < recipe.markup.count else { return }
            change(&recipe.markup[index])
        }
        if isLive { live(apply) } else { commit(action, apply) }
    }

    func deleteSelectedMarkup() {
        guard let id = selectedMarkupID else { return }
        selectedMarkupID = nil
        commit("Delete Markup") { $0.markup.removeAll { $0.id == id } }
    }

    func setMarkupColor(_ color: RGBA) {
        markupColor = color
        if selectedMarkup != nil { updateSelectedMarkup("Change Color") { $0.color = color } }
    }

    // MARK: Zoom and pan

    /// What the canvas shows, in pixels: the cropped (and resized) output, or the whole
    /// canvas while cropping.
    var displayPixelSize: CGSize {
        let g = geometry
        return tab == .crop && !comparing ? g.canvasSize : (comparing ? source.pixelSize : g.outputSize)
    }

    /// Space kept clear around a fitted picture; the top leaves room for the context bar.
    var canvasInsets: EdgeInsets {
        showRulers ? EdgeInsets(top: 88, leading: 52, bottom: 32, trailing: 32) : EdgeInsets(top: 68, leading: 32, bottom: 32, trailing: 32)
    }

    var fitZoom: Double { CanvasViewport.fitZoom(image: displayPixelSize, view: viewportSize, insets: canvasInsets) }

    var zoomScale: Double { zoom ?? fitZoom }

    /// Where the picture sits in the canvas.
    var viewport: CanvasViewport {
        let size = displayPixelSize
        return CanvasViewport(
            imageSize: size, viewSize: viewportSize, insets: canvasInsets, zoom: zoomScale,
            center: center ?? CGPoint(x: size.width / 2, y: size.height / 2)
        ).clamped()
    }

    func zoomIn() { setZoom(zoomScale * 1.25) }
    func zoomOut() { setZoom(zoomScale / 1.25) }
    func zoomToFit() {
        zoom = nil
        center = nil
    }
    func actualSize() { setZoom(1) }

    /// Zoom to `value` keeping the picture point under `anchor` (canvas points) fixed.
    func setZoom(_ value: Double, at anchor: CGPoint? = nil) {
        let z = min(32, max(0.02, value))
        let v = viewport.zoomed(to: z, anchor: anchor ?? viewport.contentCenter).clamped()
        center = v.center
        zoom = z
    }

    func pan(by delta: CGSize) { center = viewport.panned(by: delta).clamped().center }

    /// Fill the canvas with the selection, else the selected layer, else the picture.
    func zoomToSelection() {
        guard let rect = focusBounds else { return zoomToFit() }
        let display = rect.applying(displayTransform(for: displayPixelSize))
        let v = viewport.fitting(display)
        center = v.center
        zoom = min(32, v.zoom)
    }

    /// The selection's bounds when its shapes say so cheaply, else the selected layer's.
    var focusBounds: CGRect? {
        if let spec = selectionState.spec, !spec.inverted {
            let rects = spec.ops.filter { $0.mode != .subtract }.map { op -> CGRect? in
                switch op.shape {
                case .rect(let r), .ellipse(let r): r
                case .polygon(let points): points.isEmpty ? nil : Self.bounds(points)
                case .path(let path): path.cgPath.boundingBoxOfPath
                default: nil
                }
            }
            if !rects.isEmpty, rects.allSatisfy({ $0 != nil }) { return rects.compactMap(\.self).reduce(CGRect.null) { $0.union($1) } }
        }
        if let layer = selectedLayer {
            let b = LayerCompositor.bounds(of: layer, assets: document.assets)
            if !b.isNull { return b }
        }
        return nil
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Source pixel under a canvas point.
    func sourcePoint(atCanvas point: CGPoint) -> CGPoint {
        viewport.toImage(point).applying(displayTransform(for: displayPixelSize).inverted())
    }

    /// Track the pointer for the status bar: its source pixel and the color there.
    func updateCursor(atCanvas point: CGPoint?) {
        guard let point, viewport.pictureFrame.contains(point) else {
            if cursor != nil { cursor = nil }
            return
        }
        let display = viewport.toImage(point)
        let source = display.applying(displayTransform(for: displayPixelSize).inverted())
        cursor = CanvasCursor(point: CGPoint(x: source.x.rounded(.down), y: source.y.rounded(.down)), color: color(atDisplay: display))
    }

    /// The preview's color at a display pixel.
    func color(atDisplay point: CGPoint) -> RGBA? {
        guard let preview, !comparing else { return nil }
        let size = displayPixelSize
        let x = Int(point.x / max(1, size.width) * Double(preview.width)), y = Int(point.y / max(1, size.height) * Double(preview.height))
        guard x >= 0, y >= 0, x < preview.width, y < preview.height, let pixel = preview.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBA(red: Double(rgba[0]) / 255, green: Double(rgba[1]) / 255, blue: Double(rgba[2]) / 255)
    }

    /// Crop away fully transparent borders (cut-outs, pasted layers).
    func trimTransparentEdges() {
        guard tab != .crop, let preview, let box = Self.opaqueBounds(preview),
            box.width < Double(preview.width) || box.height < Double(preview.height)
        else { return showToast("Nothing to trim") }
        let w = Double(preview.width), h = Double(preview.height), c = recipe.crop
        commit("Trim") {
            $0.crop = CGRect(
                x: c.minX + box.minX / w * c.width, y: c.minY + box.minY / h * c.height, width: box.width / w * c.width,
                height: box.height / h * c.height)
        }
    }

    /// The bounding box of pixels that aren't fully transparent, top-left origin.
    nonisolated static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &alpha, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var (minX, minY, maxX, maxY) = (w, h, -1, -1)
        for y in 0..<h {
            for x in 0..<w where alpha[y * w + x] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: Tools

    private func toolChanged(from old: ImageTool) {
        if tool == .crop {
            tab = .crop
        } else if old == .crop, tab == .crop {
            tab = stripTab
        }
    }

    /// Pressing a tool's key: select it, or cycle its variants when it is already active
    /// (selection shapes, retouch tools, shapes), as Photoshop does with ⇧.
    func chooseTool(_ next: ImageTool) {
        guard next == tool else { return tool = next }
        switch next {
        case .select: selectionState.tool = Self.cycle(selectionState.tool)
        case .retouch: retouchState.tool = Self.cycle(retouchState.tool)
        case .shape: options.shape = Self.cycle(options.shape)
        case .brush: tool = .eraser
        case .eraser: tool = .brush
        case .hand: tool = .zoom
        case .zoom: tool = .hand
        default: break
        }
    }

    private static func cycle<T: CaseIterable & Equatable>(_ value: T) -> T {
        let all = Array(T.allCases)
        let i = all.firstIndex(of: value) ?? 0
        return all[(i + 1) % all.count]
    }

    /// What clicking does now, for the status bar.
    var toolHint: String {
        if spacePanning { return "Drag to pan" }
        switch tool {
        case .move: return selectedLayer == nil ? "Click a layer to select it" : "Drag to move, handles to scale, ⌘-drag a corner for perspective"
        case .select: return "\(selectionState.tool.title): ⇧ adds, ⌥ subtracts"
        case .crop: return "Drag the handles to crop, Return when done"
        case .retouch: return retouchState.tool.needsSource ? "⌥-click to set the source, then paint" : "Paint over what to \(retouchState.tool.title.lowercased())"
        case .brush: return "Drag to paint, [ and ] change the size"
        case .eraser: return "Drag over a paint layer to erase"
        case .text: return "Click to add text"
        case .shape: return "Drag to draw a \(options.shape.title.lowercased())"
        case .gradient: return "Drag to set the gradient's direction"
        case .eyedropper: return tab == .tone ? "Click something neutral to fix white balance" : "Click to pick a color"
        case .hand: return "Drag to pan, double-click to fit"
        case .zoom: return options.zoomOut ? "Click to zoom out, ⌥-click to zoom in" : "Click to zoom in, ⌥-click to zoom out"
        }
    }

    /// Brush size up (`+1`) or down (`−1`) by a step that suits the size, like [ and ].
    func stepBrushSize(_ direction: Int) {
        let step = options.brushSize < 10 ? 1.0 : options.brushSize < 50 ? 5 : 10
        options.brushSize = min(500, max(1, options.brushSize + step * Double(direction)))
        retouchState.radius = min(250, max(1, retouchState.radius + step / 2 * Double(direction)))
    }

    // MARK: Rendering

    private nonisolated struct RenderRequest: Equatable, Sendable {
        var recipe: EditRecipe
        var scale: Double
        var canvas: Bool
        /// Index of the selected top-level layer; the layers below it are cached.
        var active: Int?
    }

    /// Build the canvas graph for the current state. Requests coalesce: while one build
    /// runs, only the newest waiting request survives, so slider drags never queue up.
    /// The first pass uses the screen-sized proxy; when zoomed past it, a full-resolution
    /// pass follows once things settle. The canvas renders only what is visible.
    func requestRender() {
        let canvas = tab == .crop
        var r = canvas ? recipe.withoutCrop : recipe
        r.markup = []  // drawn live by the overlay
        r.resize = nil  // the view stretches to the output aspect
        r.stripMetadata = false
        r.guides = []
        let g = ImageGeometry(sourceSize: source.pixelSize, recipe: r)
        let shown = canvas ? g.canvasSize : g.croppedSize
        let displayed = canvas ? g.canvasSize : geometry.outputSize
        let wanted = min(1, displayed.width * zoomScale * backingScale / max(1, shown.width))
        let active = layerState.selectedID.flatMap { id in r.layers.firstIndex { $0.id == id } }
        enqueue(RenderRequest(recipe: r, scale: source.proxyScale, canvas: canvas, active: active))
        refineTask?.cancel()
        if wanted > source.proxyScale * 1.25 {
            let fine = RenderRequest(recipe: r, scale: wanted, canvas: canvas, active: active)
            refineTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self.enqueue(fine)
            }
        }
    }

    private func enqueue(_ request: RenderRequest) {
        guard request != lastRender || frame == nil else { return }
        pendingRender = request
        guard renderTask == nil else { return }
        renderTask = Task {
            while let next = pendingRender {
                pendingRender = nil
                let (source, assets, cache) = (self.source, document.assets, belowCache)
                do {
                    let (built, below) = try await offCooperativePool {
                        try Self.canvasGraph(source: source, assets: assets, request: next, cache: cache)
                    }
                    frame = built
                    belowCache = below ?? belowCache
                    lastRender = next
                    if next.scale <= source.proxyScale + 0.0001 { refreshPreview(built) }
                } catch {
                    log.error("Preview render failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            renderTask = nil
        }
    }

    /// Rasterize `frame` for the histogram and friends once edits pause.
    private func refreshPreview(_ frame: CanvasFrame) {
        previewTask?.cancel()
        let colorSpace = source.colorSpace
        previewTask = Task {
            if preview != nil { try? await Task.sleep(for: .milliseconds(90)) }
            guard !Task.isCancelled else { return }
            let image = try? await offCooperativePool {
                try RenderPipeline.rasterize(frame.image, extent: frame.extent, format: .RGBA8, colorSpace: colorSpace)
            }
            guard !Task.isCancelled, let image else { return }
            preview = image
        }
    }

    /// The preview graph: `RenderPipeline.composite` without the save-only steps, with
    /// the layers below the selected one folded into a cached intermediate.
    nonisolated private static func canvasGraph(
        source: SourceImage, assets: any AssetStore, request: RenderRequest, cache: BelowLayers?
    ) throws -> (CanvasFrame, BelowLayers?) {
        let r = request.recipe
        let geometry = ImageGeometry(sourceSize: source.pixelSize, recipe: r)
        let scale = min(1, max(0.001, request.scale))
        func base() throws -> CIImage {
            let input = try RenderPipeline.input(for: source, raw: geometry.recipe.raw, scale: scale)
            let mask = r.removeBackground ? try source.subjectMask() : nil
            return RenderPipeline.filtered(input, recipe: geometry.recipe, assets: assets, scale: scale, mask: mask)
        }
        var image: CIImage
        var below: BelowLayers?
        let layers = geometry.recipe.layers
        if let active = request.active, active > 0, active < layers.count, !layers[active].clipsToBelow {
            var key = geometry.recipe
            key.layers = Array(layers[..<active])
            if let cache, cache.key == key, cache.scale == scale {
                below = cache
            } else {
                let stack = LayerCompositor.composite(base: try base(), layers: key.layers, assets: assets, scale: scale)
                below = BelowLayers(key: key, scale: scale, image: stack.insertingIntermediate(cache: true))
            }
            image = LayerCompositor.composite(base: below!.image, layers: Array(layers[active...]), assets: assets, scale: scale)
        } else {
            image = try base()
            if !layers.isEmpty { image = LayerCompositor.composite(base: image, layers: layers, assets: assets, scale: scale) }
        }
        image = RenderPipeline.transformed(image, geometry: geometry, scale: scale, cropped: !request.canvas)
        let size = request.canvas ? geometry.canvasSize : geometry.croppedSize
        let extent = CGRect(x: 0, y: 0, width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        return (CanvasFrame(image: image.cropped(to: extent), extent: extent), below)
    }

    private func tabChanged(from old: InspectorTab) {
        liveTextEnabled = false
        if InspectorTab.strip.contains(old) { stripTab = old }
        if tab == .crop { tool = .crop } else if tool == .crop { tool = .move }
        if tab != .markup { selectedMarkupID = nil }
        center = nil
        requestRender()
        refreshThumbnailsIfVisible()
    }

    /// Filter thumbnails are the current edit (minus the filter) under each preset,
    /// rendered small in the background.
    func refreshThumbnailsIfVisible() {
        guard tab == .filters else { return }
        thumbnailTask?.cancel()
        var base = recipe
        base.filter = nil
        base.markup = []
        base.resize = nil
        let source = self.source
        let assets = document.assets
        let longEdge = max(geometry.croppedSize.width, geometry.croppedSize.height)
        let scale = min(source.proxyScale, 180 / max(1.0, Double(longEdge)))
        let frozen = base
        thumbnailTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            guard
                let rendered = try? await offCooperativePool({
                    Self.renderFilterThumbnails(source: source, assets: assets, recipe: frozen, scale: scale)
                }), !Task.isCancelled
            else { return }
            filterBase = rendered.0
            filterThumbnails = rendered.1
        }
    }

    /// Renders the filter-picker thumbnails (blocking; run it with `offCooperativePool`).
    nonisolated private static func renderFilterThumbnails(
        source: SourceImage, assets: any AssetStore, recipe: EditRecipe, scale: Double
    ) -> (CGImage?, [FilterPreset: CGImage]) {
        guard let image = try? RenderPipeline.render(source, recipe: recipe, assets: assets, scale: scale) else { return (nil, [:]) }
        var out: [FilterPreset: CGImage] = [:]
        let ci = CIImage(cgImage: image)
        for preset in FilterPreset.allCases {
            let looked = RenderPipeline.apply(preset, strength: 1, to: ci)
            out[preset] = RenderPipeline.context.createCGImage(looked, from: ci.extent)
        }
        return (image, out)
    }

    /// Decode the full-resolution original in the background after first paint.
    func warmUp() {
        let source = self.source
        DispatchQueue.global(qos: .utility).async { source.warmUp() }
        DispatchQueue.global(qos: .background).async { EditSessionStore.shared.prune() }
    }

    // MARK: Feedback

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func show(_ error: any Error, title: String) {
        log.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        Alert.show(error, title: title)
    }

    func runBusy(_ message: String, _ work: @escaping () async -> Void) {
        guard busyMessage == nil else { return }
        busyMessage = message
        Task {
            await work()
            busyMessage = nil
        }
    }
}
