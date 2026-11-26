import FolioKit
import SwiftUI

extension ImageEditorModel {
    /// Source pixels → points in a picture frame of `size`. Uses the canvas while
    /// cropping, the crop otherwise, so markup tracks whatever is on screen.
    func displayTransform(for size: CGSize) -> CGAffineTransform {
        let g = geometry
        let crop = tab == .crop
        let base = crop ? g.canvasTransform : g.croppedTransform
        let shown = crop ? g.canvasSize : g.croppedSize
        return base.concatenating(CGAffineTransform(scaleX: size.width / max(1, shown.width), y: size.height / max(1, shown.height)))
    }
}

/// Draws markup over the picture and, in the Markup tab, turns drags into strokes,
/// shapes and moves.
struct MarkupOverlay: View {
    let model: ImageEditorModel
    let size: CGSize
    @State private var start: CGPoint?
    @State private var moving: MarkupItem?

    private var interactive: Bool { model.tab == .markup && !model.liveTextEnabled }

    var body: some View {
        let transform = model.displayTransform(for: size)
        Canvas { ctx, _ in
            var items = model.recipe.markup
            if let draft = model.draftMarkup { items.append(draft) }
            if !items.isEmpty {
                ctx.withCGContext { cg in MarkupDrawing.draw(items, in: cg, transform: transform) }
            }
            if interactive, let selected = model.selectedMarkup {
                let box = selected.bounds.applying(transform).insetBy(dx: -4, dy: -4)
                ctx.stroke(
                    Path(roundedRect: box, cornerRadius: Hero.Radius.sm),
                    with: .color(Hero.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(.rect)
        .allowsHitTesting(interactive)
        .pointerStyle(model.markupTool == .select ? .default : model.markupTool == .text ? .horizontalText : .rectSelection)
        .gesture(drag(transform: transform))
        .accessibilityHidden(!interactive)
        .accessibilityLabel("Markup canvas")
        .accessibilityHint("Drag to draw with the \(model.markupTool.title.lowercased()) tool.")
    }

    private func drag(transform: CGAffineTransform) -> some Gesture {
        let inverse = transform.inverted()
        // Source pixels per screen point, for widths and hit-test tolerance.
        let pixelsPerPoint = 1 / max(0.0001, hypot(transform.a, transform.b))
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = value.location.applying(inverse)
                if start == nil { begin(at: value.startLocation.applying(inverse), pixelsPerPoint: pixelsPerPoint) }
                update(to: point, pixelsPerPoint: pixelsPerPoint)
            }
            .onEnded { value in
                finish(
                    at: value.location.applying(inverse), moved: hypot(value.translation.width, value.translation.height),
                    pixelsPerPoint: pixelsPerPoint)
            }
    }

    private func begin(at point: CGPoint, pixelsPerPoint: Double) {
        start = point
        switch model.markupTool {
        case .select:
            let hit = model.recipe.markup.last { $0.contains(point, tolerance: 6 * pixelsPerPoint) }
            model.selectedMarkupID = hit?.id
            moving = hit
        case .text:
            break
        case .pen, .highlighter, .arrow, .rectangle, .ellipse:
            guard let kind = model.markupTool.kind else { return }
            let width = model.markupWidth * (kind == .highlighter ? 4 : 1) * pixelsPerPoint
            let points = [.pen, .highlighter].contains(kind) ? [point] : [point, point]
            model.draftMarkup = MarkupItem(kind: kind, points: points, color: model.markupColor, lineWidth: width)
        }
    }

    private func update(to point: CGPoint, pixelsPerPoint: Double) {
        guard let start else { return }
        if let moving {
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            model.live { recipe in
                if let index = recipe.markup.firstIndex(where: { $0.id == moving.id }) {
                    recipe.markup[index] = moving.offset(by: delta)
                }
            }
            return
        }
        guard var draft = model.draftMarkup else { return }
        switch draft.kind {
        case .pen, .highlighter:
            // Skip sub-point jitter so strokes stay light.
            if let last = draft.points.last, hypot(last.x - point.x, last.y - point.y) < pixelsPerPoint { return }
            draft.points.append(point)
        default:
            draft.points = [start, point]
        }
        model.draftMarkup = draft
    }

    private func finish(at point: CGPoint, moved: Double, pixelsPerPoint: Double) {
        defer { start = nil; moving = nil; model.draftMarkup = nil }
        if moving != nil {
            model.endLive("Move Markup")
            return
        }
        if model.markupTool == .text {
            let item = MarkupItem(
                kind: .text, points: [point], color: model.markupColor, lineWidth: 0,
                text: "Text", fontSize: 24 * pixelsPerPoint)
            model.commit("Add Text") { $0.markup.append(item) }
            model.selectedMarkupID = item.id
            model.focusMarkupText = true
            return
        }
        guard let draft = model.draftMarkup else { return }
        let isStroke = draft.kind == .pen || draft.kind == .highlighter
        // A click without a drag only makes sense for a dot.
        guard isStroke || moved > 3 else { return }
        model.commit("Add \(draft.kind.rawValue.capitalized)") { $0.markup.append(draft) }
        model.selectedMarkupID = draft.id
    }
}
