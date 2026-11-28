import FolioKit
import SwiftUI

/// Snapping and ruler spacing as plain math.
nonisolated enum GuideSnapping {
    /// The target nearest `value` within `tolerance`, or `nil`.
    static func snap(_ value: Double, to targets: [Double], tolerance: Double) -> Double? {
        targets.filter { abs($0 - value) <= tolerance }.min { abs($0 - value) < abs($1 - value) }
    }

    /// The smallest shift that puts one of `edges` (a box's min, mid and max) on a target.
    static func offset(_ edges: [Double], to targets: [Double], tolerance: Double) -> Double? {
        var best: Double?
        for edge in edges {
            guard let target = snap(edge, to: targets, tolerance: tolerance) else { continue }
            if best.map({ abs(target - edge) < abs($0) }) ?? true { best = target - edge }
        }
        return best
    }

    /// Ruler tick spacing in pixels: 1, 2 or 5 × 10ⁿ, at least `minimum` points apart.
    static func tickStep(zoom: Double, minimum: Double = 60) -> Double {
        let raw = minimum / max(0.0001, zoom)
        let magnitude = pow(10, floor(log10(raw)))
        return [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? 10 * magnitude
    }
}

extension ImageEditorModel {
    /// Where things snap along `axis` (source pixels): guides, the document's edges and middle.
    func snapTargets(_ axis: Guide.Axis, excluding guide: UUID? = nil) -> [Double] {
        guard snapToGuides else { return [] }
        let size = source.pixelSize
        let length = axis == .vertical ? size.width : size.height
        return recipe.guides.filter { $0.axis == axis && $0.id != guide }.map(\.position) + [0, length / 2, length]
    }

    func addGuide(_ axis: Guide.Axis, at position: Double) {
        commit("Add Guide") { $0.guides.append(Guide(axis: axis, position: position)) }
    }

    func clearGuides() { commit("Clear Guides") { $0.guides = [] } }

    /// A screen-horizontal line is a source-vertical one when the picture is turned a quarter.
    var guidesSwapAxes: Bool {
        let t = displayTransform(for: displayPixelSize)
        return abs(t.b) > abs(t.a)
    }
}

/// The document's guides over the picture. With the move tool, drag one to move it, or
/// off the picture to remove it.
struct RulersAndGuides: View {
    let model: ImageEditorModel
    /// The picture frame in points, as for `MarkupOverlay`.
    let size: CGSize

    var body: some View {
        let transform = model.displayTransform(for: size)
        ZStack(alignment: .topLeading) {
            ForEach(model.recipe.guides) { guide in
                let line = path(guide, transform: transform)
                line.stroke(Hero.accent, lineWidth: 1)
                    .contentShape(line.strokedPath(StrokeStyle(lineWidth: 8)))
                    .gesture(drag(guide, inverse: transform.inverted()))
                    .pointerStyle((guide.axis == .horizontal) != model.guidesSwapAxes ? .frameResize(position: .top) : .frameResize(position: .leading))
                    .allowsHitTesting(model.tool == .move)
                    .accessibilityElement()
                    .accessibilityLabel("\(guide.axis == .horizontal ? "Horizontal" : "Vertical") guide")
                    .accessibilityValue("\(Int(guide.position.rounded())) pixels")
                    .accessibilityAction(named: "Remove") { model.commit("Remove Guide") { $0.guides.removeAll { $0.id == guide.id } } }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func path(_ guide: Guide, transform: CGAffineTransform) -> Path {
        let s = model.source.pixelSize
        let (a, b) =
            guide.axis == .horizontal
            ? (CGPoint(x: 0, y: guide.position), CGPoint(x: s.width, y: guide.position))
            : (CGPoint(x: guide.position, y: 0), CGPoint(x: guide.position, y: s.height))
        return Path { $0.move(to: a.applying(transform)); $0.addLine(to: b.applying(transform)) }
    }

    private func drag(_ guide: Guide, inverse: CGAffineTransform) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let p = value.location.applying(inverse)
                var position = guide.axis == .horizontal ? p.y : p.x
                let tolerance = 6 / max(0.0001, model.zoomScale)
                position = GuideSnapping.snap(position, to: model.snapTargets(guide.axis, excluding: guide.id), tolerance: tolerance) ?? position
                model.live { recipe in
                    if let i = recipe.guides.firstIndex(where: { $0.id == guide.id }) { recipe.guides[i].position = position.rounded() }
                }
            }
            .onEnded { value in
                if CGRect(origin: .zero, size: size).contains(value.location) {
                    model.endLive("Move Guide")
                } else {
                    model.commit("Remove Guide") { $0.guides.removeAll { $0.id == guide.id } }
                }
            }
    }
}

/// Rulers along the top and left of the canvas in display pixels, marking the pointer.
/// Drag out of a ruler to add a guide.
struct CanvasRulers: View {
    let model: ImageEditorModel
    let viewport: CanvasViewport
    static let thickness: CGFloat = 20
    /// The guide being dragged out: the ruler it came from and where it is (view points).
    @State private var draft: (fromTop: Bool, at: CGPoint)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let draft {
                Path { p in
                    if draft.fromTop {
                        p.move(to: CGPoint(x: 0, y: draft.at.y)); p.addLine(to: CGPoint(x: viewport.viewSize.width, y: draft.at.y))
                    } else {
                        p.move(to: CGPoint(x: draft.at.x, y: 0)); p.addLine(to: CGPoint(x: draft.at.x, y: viewport.viewSize.height))
                    }
                }
                .stroke(Hero.accent, lineWidth: 1)
                .allowsHitTesting(false)
            }
            ruler(top: true)
                .frame(width: viewport.viewSize.width, height: Self.thickness)
            ruler(top: false)
                .frame(width: Self.thickness, height: viewport.viewSize.height)
            Rectangle().fill(Hero.surface).frame(width: Self.thickness, height: Self.thickness)
                .overlay(alignment: .bottomTrailing) { Rectangle().fill(Hero.border).frame(width: 1, height: 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rulers")
        .accessibilityHint("Drag from a ruler to add a guide.")
    }

    private func ruler(top: Bool) -> some View {
        let cursor = model.cursor.map { $0.point.applying(model.displayTransform(for: model.displayPixelSize)) }
        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Hero.surface))
            let edge = top ? CGRect(x: 0, y: size.height - 1, width: size.width, height: 1) : CGRect(x: size.width - 1, y: 0, width: 1, height: size.height)
            ctx.fill(Path(edge), with: .color(Hero.border))
            let step = GuideSnapping.tickStep(zoom: viewport.zoom)
            let length = top ? size.width : size.height
            let first = viewport.toImage(.zero), last = viewport.toImage(CGPoint(x: length, y: length))
            let lo = ((top ? first.x : first.y) / step).rounded(.down) * step, hi = top ? last.x : last.y
            var ticks = Path()
            var value = lo
            while value <= hi {
                let v = top ? viewport.toView(CGPoint(x: value, y: 0)).x : viewport.toView(CGPoint(x: 0, y: value)).y
                for minor in 1..<5 {
                    let m = v + Double(minor) * step / 5 * viewport.zoom
                    if top { ticks.addRect(CGRect(x: m, y: size.height - 5, width: 1, height: 4)) } else { ticks.addRect(CGRect(x: size.width - 5, y: m, width: 4, height: 1)) }
                }
                if top { ticks.addRect(CGRect(x: v, y: 4, width: 1, height: size.height - 4)) } else { ticks.addRect(CGRect(x: 4, y: v, width: size.width - 4, height: 1)) }
                let label = ctx.resolve(Text("\(Int(value))").font(.system(size: 10)).monospacedDigit().foregroundStyle(Hero.muted))
                if top {
                    ctx.draw(label, at: CGPoint(x: v + 3, y: 2), anchor: .topLeading)
                } else {
                    var c = ctx
                    c.translateBy(x: 2, y: v + 3)
                    c.rotate(by: .degrees(90))
                    c.draw(label, at: .zero, anchor: .bottomLeading)
                }
                value += step
            }
            ctx.fill(ticks, with: .color(Hero.muted.opacity(0.6)))
            if let cursor {
                let v = viewport.toView(cursor)
                ctx.fill(Path(top ? CGRect(x: v.x, y: 0, width: 1, height: size.height) : CGRect(x: 0, y: v.y, width: size.width, height: 1)), with: .color(Hero.accent))
            }
        }
        .contentShape(.rect)
        .gesture(
            DragGesture()
                .onChanged { value in draft = (top, value.location) }
                .onEnded { value in
                    draft = nil
                    guard viewport.pictureFrame.contains(value.location) else { return }
                    let p = model.sourcePoint(atCanvas: value.location)
                    let horizontalOnScreen = top
                    let axis: Guide.Axis = horizontalOnScreen != model.guidesSwapAxes ? .horizontal : .vertical
                    model.addGuide(axis, at: (axis == .horizontal ? p.y : p.x).rounded())
                }
        )
        .pointerStyle(top ? .frameResize(position: .top) : .frameResize(position: .leading))
    }
}
