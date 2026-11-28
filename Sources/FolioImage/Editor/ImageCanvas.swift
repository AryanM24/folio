import AppKit
import CoreImage
import FolioKit
import MetalKit
import SwiftUI

// MARK: - Viewport math

/// Where the picture sits in the canvas: zoom and pan as plain math. Image coordinates
/// are display pixels (top-left origin, y down); view coordinates are points.
nonisolated struct CanvasViewport: Equatable, Sendable {
    var imageSize: CGSize
    var viewSize: CGSize
    /// Space kept clear around a fitted picture.
    var insets = EdgeInsets()
    /// Points per display pixel.
    var zoom: Double
    /// The display pixel at the middle of the content area.
    var center: CGPoint

    var contentRect: CGRect {
        CGRect(
            x: insets.leading, y: insets.top, width: max(1, viewSize.width - insets.leading - insets.trailing),
            height: max(1, viewSize.height - insets.top - insets.bottom))
    }
    var contentCenter: CGPoint { CGPoint(x: contentRect.midX, y: contentRect.midY) }
    /// Where display pixel (0, 0) lands.
    var origin: CGPoint { CGPoint(x: contentRect.midX - center.x * zoom, y: contentRect.midY - center.y * zoom) }
    var pictureFrame: CGRect { CGRect(origin: origin, size: CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)) }

    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * zoom, y: origin.y + p.y * zoom) }
    func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / zoom, y: (p.y - origin.y) / zoom) }

    /// The part of the picture on screen, in display pixels.
    var visibleImageRect: CGRect {
        CGRect(origin: toImage(.zero), size: CGSize(width: viewSize.width / zoom, height: viewSize.height / zoom))
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// The largest zoom (at most 100 %) that shows all of `image` inside the insets.
    static func fitZoom(image: CGSize, view: CGSize, insets: EdgeInsets) -> Double {
        let w = view.width - insets.leading - insets.trailing, h = view.height - insets.top - insets.bottom
        guard image.width > 0, image.height > 0, w > 0, h > 0 else { return 1 }
        return min(1, w / image.width, h / image.height)
    }

    /// Zoom to `newZoom` keeping the image point under `anchor` (view points) in place.
    func zoomed(to newZoom: Double, anchor: CGPoint) -> CanvasViewport {
        let fixed = toImage(anchor)
        var v = self
        v.zoom = newZoom
        v.center = CGPoint(x: fixed.x - (anchor.x - contentRect.midX) / newZoom, y: fixed.y - (anchor.y - contentRect.midY) / newZoom)
        return v
    }

    /// Move the picture by `delta` points.
    func panned(by delta: CGSize) -> CanvasViewport {
        var v = self
        v.center = CGPoint(x: center.x - delta.width / zoom, y: center.y - delta.height / zoom)
        return v
    }

    /// Keep the picture on screen: centered on an axis where it fits, else edge to edge.
    func clamped() -> CanvasViewport {
        func axis(_ c: Double, length: Double, span: Double) -> Double {
            let half = span / 2 / zoom
            return length * zoom <= span ? length / 2 : min(max(c, half), length - half)
        }
        var v = self
        let area = contentRect
        v.center = CGPoint(x: axis(center.x, length: imageSize.width, span: area.width), y: axis(center.y, length: imageSize.height, span: area.height))
        return v
    }

    /// Zoomed and centered so `rect` (display pixels) fills the content area.
    func fitting(_ rect: CGRect) -> CanvasViewport {
        guard rect.width > 0, rect.height > 0 else { return self }
        var v = self
        v.zoom = min(contentRect.width / rect.width, contentRect.height / rect.height)
        v.center = CGPoint(x: rect.midX, y: rect.midY)
        return v
    }

    /// Graph pixels (Core Image, y up, `extent` covering the picture) → drawable pixels
    /// (y up, `drawableHeight` tall) at `backing` pixels per point.
    func ciTransform(extent: CGRect, drawableHeight: Double, backing: Double) -> CGAffineTransform {
        let sx = imageSize.width / max(1, extent.width) * zoom * backing
        let sy = imageSize.height / max(1, extent.height) * zoom * backing
        return CGAffineTransform(
            a: sx, b: 0, c: 0, d: sy, tx: origin.x * backing - extent.minX * sx,
            ty: drawableHeight - (origin.y + imageSize.height * zoom) * backing - extent.minY * sy)
    }
}

// MARK: - Rendering

/// The canvas's Metal queue and Core Image context (its own, so its intermediate cache
/// holds what's on screen).
enum CanvasRenderer {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    static let context: CIContext =
        queue.map { CIContext(mtlCommandQueue: $0, options: [.name: "Folio Canvas", .cacheIntermediates: true, .workingFormat: CIFormat.RGBAh]) }
        ?? RenderPipeline.context

    /// `frame` placed in a drawable of `size` pixels: nearest-neighbour when a pixel is
    /// bigger than two on screen, over a checkerboard when the picture has transparency.
    static func composed(
        _ frame: CanvasFrame, viewport: CanvasViewport, size: CGSize, backing: Double, checker: (CIColor, CIColor)?
    ) -> CIImage {
        let t = viewport.ciTransform(extent: frame.extent, drawableHeight: size.height, backing: backing)
        var image = t.a > 2 ? frame.image.samplingNearest() : frame.image
        image = image.transformed(by: t, highQualityDownsample: t.a < 1)
        let bounds = CGRect(origin: .zero, size: size)
        if let (light, dark) = checker {
            let checks = CIFilter(
                name: "CICheckerboardGenerator",
                parameters: ["inputColor0": light, "inputColor1": dark, "inputWidth": 8 * backing, "inputSharpness": 1])?
                .outputImage?.cropped(to: image.extent)
            if let checks { image = image.composited(over: checks) }
        }
        return image.cropped(to: bounds)
    }
}

/// The `MTKView` that draws the picture, and takes scroll, pinch, the hand and zoom
/// tools and pointer tracking for the whole canvas.
final class CanvasMetalView: MTKView, MTKViewDelegate {
    weak var model: ImageEditorModel?
    var canvasFrame: CanvasFrame?
    var viewport = CanvasViewport(imageSize: .zero, viewSize: .zero, zoom: 1, center: .zero)
    var hasAlpha = false
    /// Hand or zoom tool, or space held: mouse drags belong to this view.
    var handlesMouse = false

    private var monitor: Any?
    private var outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    /// `scripts/snapshot.sh` draws views into a bitmap, which skips Metal, so the canvas
    /// shows the preview bitmap instead in that mode.
    static let skippedBySnapshots = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT_DIR"] != nil

    init() {
        super.init(frame: .zero, device: CanvasRenderer.device)
        delegate = self
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = false
        autoResizeDrawable = true
        layer?.isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        configureColor()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { false }

    /// Extended range on screens that have headroom, so HDR content isn't clipped.
    private func configureColor() {
        let edr = (window?.screen ?? NSScreen.main)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1 > 1
        colorPixelFormat = edr ? .rgba16Float : .bgra8Unorm
        outputSpace = CGColorSpace(name: edr ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.displayP3)!
        colorspace = outputSpace
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = edr
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureColor()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        configureColor()
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let buffer = CanvasRenderer.queue?.makeCommandBuffer(), let drawable = currentDrawable else { return }
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: buffer)
        destination.isFlipped = true
        destination.colorSpace = outputSpace
        _ = try? CanvasRenderer.context.startTask(toClear: destination)
        if let image = composed(size: drawableSize) {
            _ = try? CanvasRenderer.context.startTask(toRender: image, to: destination)
        }
        buffer.present(drawable)
        buffer.commit()
    }

    private func composed(size: CGSize) -> CIImage? {
        guard let canvasFrame, size.width > 0, size.height > 0 else { return nil }
        let backing = size.width / max(1, bounds.width)
        return CanvasRenderer.composed(canvasFrame, viewport: viewport, size: size, backing: backing, checker: hasAlpha ? checkerColors : nil)
    }

    private var checkerColors: (CIColor, CIColor) {
        var colors = (CIColor(red: 1, green: 1, blue: 1), CIColor(red: 0.92, green: 0.92, blue: 0.93))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = (CIColor(color: NSColor(Hero.surface)) ?? colors.0, CIColor(color: NSColor(Hero.default)) ?? colors.1)
        }
        return colors
    }

    // MARK: Events

    /// A point in this view, top-left origin, like SwiftUI.
    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    /// Scroll pans and ⌥/⌘-scroll zooms; pinch zooms at the pointer; a two-finger
    /// double-tap toggles fit and 100 %.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, event.window === window, !isHiddenOrHasHiddenAncestor,
            bounds.contains(convert(event.locationInWindow, from: nil))
        else { return event }
        let point = canvasPoint(event)
        switch event.type {
        case .magnify:
            model.setZoom(model.zoomScale * (1 + event.magnification), at: point)
        case .smartMagnify:
            if model.zoomScale < 0.999 { model.setZoom(1, at: point) } else { model.zoomToFit() }
        case .scrollWheel:
            let k = event.hasPreciseScrollingDeltas ? 1.0 : 10
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                model.setZoom(model.zoomScale * exp(event.scrollingDeltaY * k * 0.01), at: point)
            } else {
                model.pan(by: CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
            }
        default:
            return event
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { model?.updateCursor(atCanvas: canvasPoint(event)) }
    override func mouseExited(with event: NSEvent) { model?.updateCursor(atCanvas: nil) }

    override func mouseDown(with event: NSEvent) {
        guard let model, handlesMouse else { return super.mouseDown(with: event) }
        let point = canvasPoint(event)
        if model.tool == .zoom, !model.spacePanning {
            let out = model.options.zoomOut != event.modifierFlags.contains(.option)
            model.setZoom(model.zoomScale * (out ? 0.5 : 2), at: point)
        } else if event.clickCount == 2 {
            model.zoomToFit()
        } else {
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, handlesMouse, model.tool == .hand || model.spacePanning else { return super.mouseDragged(with: event) }
        model.pan(by: CGSize(width: event.deltaX, height: event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        guard handlesMouse else { return super.mouseUp(with: event) }
        if model?.tool == .hand || model?.spacePanning == true { NSCursor.pop() }
    }

    override func resetCursorRects() {
        guard let model, handlesMouse else { return }
        addCursorRect(bounds, cursor: model.tool == .zoom && !model.spacePanning ? .crosshair : .openHand)
    }
}

/// SwiftUI host for ``CanvasMetalView``.
private struct MetalCanvas: NSViewRepresentable {
    let model: ImageEditorModel
    let frame: CanvasFrame?
    let viewport: CanvasViewport
    let hasAlpha: Bool
    let handlesMouse: Bool

    func makeNSView(context: Context) -> CanvasMetalView { CanvasMetalView() }

    func updateNSView(_ view: CanvasMetalView, context: Context) {
        view.model = model
        view.canvasFrame = frame
        view.viewport = viewport
        view.hasAlpha = hasAlpha
        if view.handlesMouse != handlesMouse {
            view.handlesMouse = handlesMouse
            view.window?.invalidateCursorRects(for: view)
        }
        view.needsDisplay = true
    }
}

// MARK: - The canvas

/// The picture on a neutral backdrop, drawn by Metal for the visible area only, with the
/// tool overlays sized exactly to the picture and the rulers and pixel grid on top.
struct ImageCanvas: View {
    let model: ImageEditorModel

    var body: some View {
        GeometryReader { geo in
            let viewport = model.viewport
            let picture = viewport.pictureFrame
            // Only the visible part of the picture, so its shadow and outline stay cheap at any zoom.
            let backdrop = picture.intersection(CGRect(origin: .zero, size: geo.size).insetBy(dx: -24, dy: -24))
            let panning = model.spacePanning || model.tool == .hand || model.tool == .zoom
            ZStack(alignment: .topLeading) {
                if shownFrame != nil {
                    Rectangle().fill(Hero.surface)
                        .frame(width: max(0, backdrop.width), height: max(0, backdrop.height))
                        .modifier(PictureShadow())
                        .offset(x: backdrop.minX, y: backdrop.minY)
                }
                if CanvasMetalView.skippedBySnapshots, let preview = model.preview, !model.comparing {
                    Image(decorative: preview, scale: 1).resizable()
                        .frame(width: picture.width, height: picture.height)
                        .offset(x: picture.minX, y: picture.minY)
                }
                MetalCanvas(model: model, frame: shownFrame, viewport: viewport, hasAlpha: hasAlpha, handlesMouse: panning)
                    .accessibilityHidden(true)
                if shownFrame != nil {
                    Color.clear
                        .frame(width: max(0, backdrop.width), height: max(0, backdrop.height))
                        .imageOutline(cornerRadius: 0)
                        .offset(x: backdrop.minX, y: backdrop.minY)
                        .allowsHitTesting(false)
                }
                if shownFrame == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                overlays(size: picture.size)
                    .frame(width: picture.width, height: picture.height)
                    .offset(x: picture.minX, y: picture.minY)
                    .allowsHitTesting(!panning)
                if model.showPixelGrid, viewport.zoom >= 8 {
                    PixelGrid(viewport: viewport).allowsHitTesting(false)
                }
                if model.showRulers {
                    CanvasRulers(model: model, viewport: viewport)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .onChange(of: geo.size, initial: true) { model.viewportSize = geo.size }
        }
        .background(Hero.backgroundSecondary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.comparing ? "Original image" : "Edited image")
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: "Zoom in") { model.zoomIn() }
        .accessibilityAction(named: "Zoom out") { model.zoomOut() }
        .accessibilityAction(named: "Zoom to fit") { model.zoomToFit() }
    }

    private var hasAlpha: Bool { model.source.hasAlpha || model.recipe.removeBackground }

    private var shownFrame: CanvasFrame? {
        guard model.comparing else { return model.frame }
        let image = model.source.proxyImage
        return CanvasFrame(image: image, extent: image.extent)
    }

    private var accessibilityValue: String {
        let size = model.displayPixelSize
        var value = "\(Int(size.width)) by \(Int(size.height)) pixels, \(Int((model.zoomScale * 100).rounded())) percent"
        if let layer = model.selectedLayer {
            let b = LayerCompositor.bounds(of: layer, assets: model.document.assets)
            value += ", layer \(layer.name) selected"
            if !b.isNull { value += " at \(Int(b.minX)), \(Int(b.minY)), \(Int(b.width)) by \(Int(b.height))" }
        }
        return value
    }

    @ViewBuilder private func overlays(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if !model.comparing {
                MarkupOverlay(model: model, size: size)
                SelectionOverlay(model: model, size: size)
                RetouchToolController(model: model, size: size)
                CanvasToolLayer(model: model, size: size)
                TransformHandles(model: model, size: size)
                if model.showGuides { RulersAndGuides(model: model, size: size) }
                if model.tab == .crop { CropOverlay(model: model, size: size) }
                if model.liveTextEnabled, let image = model.preview {
                    LiveTextOverlay(image: image).frame(width: size.width, height: size.height)
                }
            }
        }
    }
}

/// A gentle lift in light mode; none in dark mode, matching Hero surfaces.
private struct PictureShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if scheme == .dark {
            content
        } else {
            content.shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
    }
}

/// Lines between pixels once each one is 8 points or more.
private struct PixelGrid: View {
    let viewport: CanvasViewport

    var body: some View {
        Canvas { ctx, _ in
            let visible = viewport.visibleImageRect
            guard !visible.isNull else { return }
            let frame = viewport.pictureFrame.intersection(CGRect(origin: .zero, size: viewport.viewSize))
            var path = Path()
            for x in Int(visible.minX.rounded(.up))...Int(visible.maxX.rounded(.down)) {
                let vx = viewport.toView(CGPoint(x: Double(x), y: 0)).x
                path.move(to: CGPoint(x: vx, y: frame.minY))
                path.addLine(to: CGPoint(x: vx, y: frame.maxY))
            }
            for y in Int(visible.minY.rounded(.up))...Int(visible.maxY.rounded(.down)) {
                let vy = viewport.toView(CGPoint(x: 0, y: Double(y))).y
                path.move(to: CGPoint(x: frame.minX, y: vy))
                path.addLine(to: CGPoint(x: frame.maxX, y: vy))
            }
            ctx.stroke(path, with: .color(.gray.opacity(0.35)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tool gestures

/// Clicks and drags for the eyedropper, text, shape, gradient, brush and eraser tools.
/// Selection, retouch, move and crop have their own overlays.
private struct CanvasToolLayer: View {
    let model: ImageEditorModel
    let size: CGSize
    /// The drag in progress, in source pixels.
    @State private var points: [CGPoint] = []

    private static let tools: Set<ImageTool> = [.eyedropper, .text, .shape, .gradient, .brush, .eraser]
    private var active: Bool { Self.tools.contains(model.tool) && !model.comparing && model.tab != .markup }

    var body: some View {
        let transform = model.displayTransform(for: size)
        Canvas { ctx, _ in
            guard let first = points.first, let last = points.last else { return }
            let a = first.applying(transform), b = last.applying(transform)
            let color = Color(cgColor: model.options.color.cgColor)
            switch model.tool {
            case .brush, .eraser:
                let path = Path { $0.addLines(points.map { $0.applying(transform) }) }
                let style = StrokeStyle(lineWidth: model.options.brushSize, lineCap: .round, lineJoin: .round)
                ctx.stroke(path, with: model.tool == .eraser ? .color(.white.opacity(0.6)) : .color(color.opacity(model.options.opacity)), style: style)
            case .shape:
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                let outline: Path =
                    switch model.options.shape {
                    case .ellipse: Path(ellipseIn: rect)
                    case .line, .arrow: Path { $0.move(to: a); $0.addLine(to: b) }
                    default: Path(rect)
                    }
                ctx.stroke(outline, with: .color(Hero.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            case .gradient:
                ctx.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(.white), lineWidth: 3)
                ctx.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(Hero.accent), lineWidth: 1.5)
                for p in [a, b] { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Hero.accent)) }
            default: break
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(.rect)
        .allowsHitTesting(active)
        .pointerStyle(model.tool == .text ? .horizontalText : .rectSelection)
        .gesture(drag(transform: transform))
        .accessibilityHidden(!active)
        .accessibilityLabel("Canvas")
        .accessibilityHint(model.toolHint)
    }

    private func drag(transform: CGAffineTransform) -> some Gesture {
        let inverse = transform.inverted()
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = value.location.applying(inverse)
                if points.isEmpty { points = [value.startLocation.applying(inverse)] }
                if model.tool == .brush || model.tool == .eraser { points.append(point) } else { points = [points[0], point] }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 3
                finish(at: value.location.applying(inverse), moved: moved, pixelsPerPoint: 1 / max(0.0001, hypot(transform.a, transform.b)))
                points = []
            }
    }

    private func finish(at point: CGPoint, moved: Bool, pixelsPerPoint: Double) {
        let options = model.options
        let start = points.first ?? point
        switch model.tool {
        case .eyedropper:
            if model.tab == .tone {
                model.setWhiteBalance(sampleAt: point)
            } else {
                let display = point.applying(model.displayTransform(for: model.displayPixelSize))
                guard let color = model.color(atDisplay: display) else { return }
                model.options.color = color
                model.showToast("Picked \(color.hex)")
            }
        case .text:
            let size = options.fontSize * pixelsPerPoint
            var layer = Layer(name: "Text", content: .text(TextSpec(runs: [TextRun(text: "Text", size: size, color: options.color)])))
            layer.transform = CGAffineTransform(translationX: point.x, y: point.y - size / 2)
            model.addLayer(layer)
            model.tab = .layer
        case .shape:
            guard moved else { return }
            let lined = options.shape == .line || options.shape == .arrow
            let stroke = StrokeSpec(color: options.color, width: max(1, 4 * pixelsPerPoint))
            let spec = ShapeSpec(
                geometry: options.shape.geometry(from: start, to: point), fill: lined ? nil : .solid(options.color), stroke: lined ? stroke : nil)
            model.addLayer(Layer(name: options.shape.title, content: .shape(spec)))
        case .gradient:
            guard moved else { return }
            var clear = options.color
            clear.alpha = 0
            model.addGradientLayer(
                GradientSpec(
                    kind: options.gradient, stops: [ColorStop(location: 0, color: options.color), ColorStop(location: 1, color: clear)],
                    start: start, end: point))
        case .brush, .eraser:
            let erasing = model.tool == .eraser
            if erasing, case .paint = model.selectedLayer?.content {} else if erasing {
                return model.showToast("Select a paint layer to erase")
            }
            let stroke = BrushStroke(
                points: (points.count > 1 ? points : [point, point]).map { BrushStroke.Point(location: $0) }, color: options.color,
                size: options.brushSize * pixelsPerPoint, hardness: options.hardness, opacity: options.opacity, isEraser: erasing)
            model.addBrushStroke(stroke)
        default: break
        }
    }
}
