import AppKit
import Combine
import CoreImage
import FolioKit
import SwiftUI

private let log = Log.make("Image")

/// The inspector's tabs.
enum InspectorTab: String, CaseIterable, Identifiable {
    case adjust, filters, crop, markup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adjust: "Adjust"
        case .filters: "Filters"
        case .crop: "Crop"
        case .markup: "Markup"
        }
    }
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

    var tab: InspectorTab = .adjust { didSet { if tab != oldValue { tabChanged() } } }

    // Canvas
    /// Points per output pixel, or `nil` to fit the window.
    var zoom: Double? { didSet { requestRender() } }
    var viewportSize: CGSize = .zero { didSet { if viewportSize != oldValue { requestRender() } } }
    var backingScale: Double = 2
    private(set) var preview: CGImage?
    /// The preview shows the whole canvas (crop tab) rather than the crop.
    private(set) var previewShowsCanvas = false
    /// Hold-to-compare: show the untouched original.
    var comparing = false

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
            let specs = await Task.detached(priority: .userInitiated) { RenderPipeline.autoEnhance(for: source.proxyImage) }.value
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
                _ = try await Task.detached(priority: .userInitiated) { try source.subjectMask() }.value
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

    // MARK: Zoom

    /// What the canvas shows, in pixels: the cropped (and resized) output, or the whole
    /// canvas while cropping.
    var displayPixelSize: CGSize {
        let g = geometry
        return tab == .crop && !comparing ? g.canvasSize : (comparing ? source.pixelSize : g.outputSize)
    }

    /// Space kept clear around the picture; the top leaves room for the floating toolbar.
    static let canvasInsets = EdgeInsets(top: 68, leading: 32, bottom: 32, trailing: 32)

    var fitZoom: Double {
        let size = displayPixelSize
        let i = Self.canvasInsets
        let w = viewportSize.width - i.leading - i.trailing, h = viewportSize.height - i.top - i.bottom
        guard size.width > 0, size.height > 0, w > 0, h > 0 else { return 1 }
        return min(1, w / size.width, h / size.height)
    }

    var zoomScale: Double { zoom ?? fitZoom }

    func zoomIn() { setZoom(zoomScale * 1.25) }
    func zoomOut() { setZoom(zoomScale / 1.25) }
    func zoomToFit() { zoom = nil }
    func actualSize() { zoom = 1 }
    func setZoom(_ value: Double) { zoom = min(16, max(0.02, value)) }

    // MARK: Rendering

    private nonisolated struct RenderRequest: Equatable, Sendable {
        var recipe: EditRecipe
        var scale: Double
        var canvas: Bool
    }

    /// Render the preview for the current state. Requests coalesce: while one render
    /// runs, only the newest waiting request survives, so slider drags never queue up.
    /// The first pass uses the screen-sized proxy; when zoomed past it, a full-resolution
    /// pass follows once things settle.
    func requestRender() {
        let canvas = tab == .crop
        var r = canvas ? recipe.withoutCrop : recipe
        r.markup = []  // drawn live by the overlay
        r.resize = nil  // the view stretches to the output aspect
        r.stripMetadata = false
        let g = ImageGeometry(sourceSize: source.pixelSize, recipe: r)
        let shown = canvas ? g.canvasSize : g.croppedSize
        let displayed = canvas ? g.canvasSize : geometry.outputSize
        let wanted = min(1, displayed.width * zoomScale * backingScale / max(1, shown.width))
        let quick = RenderRequest(recipe: r, scale: source.proxyScale, canvas: canvas)
        enqueue(quick)
        refineTask?.cancel()
        if wanted > source.proxyScale * 1.25 {
            let fine = RenderRequest(recipe: r, scale: wanted, canvas: canvas)
            refineTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self.enqueue(fine)
            }
        }
    }

    private func enqueue(_ request: RenderRequest) {
        guard request != lastRender || preview == nil else { return }
        pendingRender = request
        guard renderTask == nil else { return }
        renderTask = Task {
            while let next = pendingRender {
                pendingRender = nil
                let source = self.source
                let result = await Self.renderPreview(source: source, request: next)
                switch result {
                case .success(let image):
                    preview = image
                    previewShowsCanvas = next.canvas
                    lastRender = next
                case .failure(let error):
                    log.error("Preview render failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            renderTask = nil
        }
    }

    private func tabChanged() {
        liveTextEnabled = false
        if tab != .markup { selectedMarkupID = nil }
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
        let longEdge = max(geometry.croppedSize.width, geometry.croppedSize.height)
        let scale = min(source.proxyScale, 180 / max(1.0, Double(longEdge)))
        thumbnailTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let rendered = await Self.renderFilterThumbnails(source: source, recipe: base, scale: scale)
            guard !Task.isCancelled else { return }
            filterBase = rendered.0
            filterThumbnails = rendered.1
        }
    }

    /// Renders one preview frame off the main actor (see `renderFilterThumbnails` for why
    /// this is a `@concurrent` function rather than a detached closure).
    @concurrent
    nonisolated private static func renderPreview(source: SourceImage, request: RenderRequest) async -> sending Result<CGImage, any Error> {
        Result { try RenderPipeline.render(source, recipe: request.recipe, scale: request.scale, cropped: !request.canvas) }
    }

    /// Renders the filter-picker thumbnails off the main actor.
    ///
    /// `@concurrent` makes the work run on the global executor by declaration rather than
    /// through a detached closure, whose isolation newer compilers infer from the
    /// surrounding main-actor code. The images are created here and handed back with
    /// `sending`, so nothing is shared while it runs.
    @concurrent
    nonisolated private static func renderFilterThumbnails(
        source: SourceImage, recipe: EditRecipe, scale: Double
    ) async -> sending (CGImage?, [FilterPreset: CGImage]) {
        guard let image = try? RenderPipeline.render(source, recipe: recipe, scale: scale) else { return (nil, [:]) }
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
        Task.detached(priority: .utility) { source.warmUp() }
        Task.detached(priority: .background) { EditSessionStore.shared.prune() }
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
