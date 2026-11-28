import AppKit
import CoreImage
import SwiftUI
import Vision

/// Marching ants for the live selection, and the selection tools' drags.
///
/// The outline is the selection mask's contours (`VNDetectContoursRequest` on the proxy
/// mask), recomputed off the main thread only when the selection changes.
struct SelectionOverlay: View {
    let model: ImageEditorModel
    /// The picture frame in points, as for `MarkupOverlay`.
    let size: CGSize

    /// The selection's outline in source pixels.
    @State private var outline: CGPath?
    /// The marquee or lasso being dragged, in source pixels.
    @State private var draft: SelectionSpec.Shape?
    /// Polygon lasso corners placed so far.
    @State private var corners: [CGPoint] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: SelectionState { model.selectionState }
    private var interactive: Bool { model.tool == .select && !model.comparing && model.tab != .crop }

    var body: some View {
        let transform = model.displayTransform(for: size)
        let ants = antsPath(transform: transform)
        TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion || ants.isEmpty)) { timeline in
            let phase = reduceMotion ? 0 : (timeline.date.timeIntervalSinceReferenceDate * 12).truncatingRemainder(dividingBy: 8)
            Canvas { ctx, _ in
                ctx.stroke(ants, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [4, 4], dashPhase: phase))
                ctx.stroke(ants, with: .color(.black), style: StrokeStyle(lineWidth: 1, dash: [4, 4], dashPhase: phase + 4))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(.rect)
        .allowsHitTesting(interactive)
        .pointerStyle(.rectSelection)
        .gesture(drag(transform: transform))
        .task(id: state.spec) { await refreshOutline() }
        .accessibilityHidden(!interactive)
        .accessibilityLabel("Selection")
        .accessibilityValue(state.spec == nil ? "Nothing selected" : "Selection active")
        .accessibilityHint("Drag or click to select with the \(state.tool.title.lowercased()) tool.")
    }

    private func antsPath(transform: CGAffineTransform) -> Path {
        var path = Path()
        if let outline { path.addPath(Path(outline), transform: transform) }
        switch draft {
        case .rect(let r): path.addPath(Path(r), transform: transform)
        case .ellipse(let r): path.addPath(Path(ellipseIn: r), transform: transform)
        case .polygon(let points): path.addPath(Path { $0.addLines(points) }, transform: transform)
        default: break
        }
        if !corners.isEmpty { path.addPath(Path { $0.addLines(corners) }, transform: transform) }
        return path
    }

    // MARK: Gestures

    private func drag(transform: CGAffineTransform) -> some Gesture {
        let inverse = transform.inverted()
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = value.startLocation.applying(inverse), point = value.location.applying(inverse)
                switch state.tool {
                case .rectangle: draft = .rect(Self.rect(start, point))
                case .ellipse: draft = .ellipse(Self.rect(start, point))
                case .lasso:
                    if case .polygon(var points) = draft {
                        points.append(point)
                        draft = .polygon(points)
                    } else {
                        draft = .polygon([start, point])
                    }
                default: break
                }
            }
            .onEnded { value in
                let point = value.location.applying(inverse)
                let tapped = hypot(value.translation.width, value.translation.height) < 3
                finish(at: point, tapped: tapped, pointsPerPixel: hypot(transform.a, transform.b))
            }
    }

    private func finish(at point: CGPoint, tapped: Bool, pointsPerPixel: Double) {
        let shape = draft
        draft = nil
        let (mode, replacing) = Self.combination(default: state.mode)
        switch state.tool {
        case .rectangle, .ellipse, .lasso:
            if tapped {
                if replacing { model.deselect() }
            } else if let shape {
                model.combine(shape, mode: mode, replacing: replacing)
            }
        case .polygon:
            guard tapped else { return }
            if corners.count > 2, let first = corners.first, hypot(first.x - point.x, first.y - point.y) * pointsPerPixel < 8 {
                model.combine(.polygon(corners), mode: mode, replacing: replacing)
                corners = []
            } else {
                corners.append(point)
            }
        case .wand:
            model.combine(
                .wand(seed: point, tolerance: state.wandTolerance, contiguous: state.contiguous, sampleAllLayers: state.sampleAllLayers),
                mode: mode, replacing: replacing)
        case .colorRange: model.selectColorRange(at: point, mode: mode, replacing: replacing)
        case .subject: model.selectSubject(at: point, mode: mode, replacing: replacing)
        case .sky: model.selectSky(mode: mode, replacing: replacing)
        }
    }

    /// Photoshop's modifiers: ⇧ adds, ⌥ subtracts, ⇧⌥ intersects; none starts a new
    /// selection, unless the tool option asks to subtract or intersect.
    private static func combination(default mode: SelectionSpec.Mode) -> (SelectionSpec.Mode, Bool) {
        let flags = NSEvent.modifierFlags
        switch (flags.contains(.shift), flags.contains(.option)) {
        case (true, true): return (.intersect, false)
        case (false, true): return (.subtract, false)
        case (true, false): return (.add, false)
        case (false, false): return (mode, mode == .add)
        }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Outline

    private func refreshOutline() async {
        guard let spec = state.spec else {
            outline = nil
            return
        }
        let path = await Self.outline(of: spec, source: model.source, recipe: model.recipe, assets: model.document.assets)
        guard !Task.isCancelled else { return }
        outline = path
    }

    /// The contours of `spec`'s mask at proxy resolution, in source pixels.
    @concurrent
    nonisolated private static func outline(
        of spec: SelectionSpec, source: SourceImage, recipe: EditRecipe, assets: any AssetStore
    ) async -> CGPath? {
        guard
            let mask = try? ImageEditorModel.selectionMask(
                spec, source: source, recipe: recipe, assets: assets, scale: source.proxyScale)
        else { return nil }
        let (bytes, w, h) = SelectionRenderer.bytes(of: mask)
        // A black border, so a selection touching the edges still has a contour there.
        let pad = 2
        guard let image = SelectionRenderer.grayImage(bytes, width: w, height: h),
            let ctx = CGContext(
                data: nil, width: w + 2 * pad, height: h + 2 * pad, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: w, height: h))
        guard let padded = ctx.makeImage() else { return nil }
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = false
        request.maximumImageDimension = min(1024, max(padded.width, padded.height))
        guard (try? VNImageRequestHandler(cgImage: padded).perform([request])) != nil,
            let contours = request.results?.first, contours.contourCount > 0
        else { return nil }
        // Normalized (y-up, padded) → source pixels (y-down).
        let pw = Double(padded.width), ph = Double(padded.height)
        let sx = source.pixelSize.width / Double(w), sy = source.pixelSize.height / Double(h)
        var transform = CGAffineTransform(a: pw * sx, b: 0, c: 0, d: -ph * sy, tx: -Double(pad) * sx, ty: (ph - Double(pad)) * sy)
        return contours.normalizedPath.copy(using: &transform)
    }
}
