import AppKit
import FolioKit
import SwiftUI

/// Move, scale, rotate and perspective handles for the selected layer, with the move tool.
///
/// Click a layer to select it and drag to move it (snapping to guides and the document's
/// edges and middle). Corner handles scale proportionally (⇧ frees them), edge handles
/// stretch one way, the knob above rotates (⇧ snaps to 15°), and ⌘-dragging a corner
/// moves just that corner for perspective. Each drag is one undo step.
struct TransformHandles: View {
    let model: ImageEditorModel
    /// The picture frame in points, as for `MarkupOverlay`.
    let size: CGSize

    /// The selected layer as the drag began.
    @State private var start: Layer?

    private var active: Bool { model.tool == .move && !model.comparing && model.tab != .crop && model.tab != .markup }

    /// Corners and edge midpoints, clockwise from the top left, as indexes into the
    /// layer's local corners (0 tl, 1 tr, 2 br, 3 bl) or their midpoints.
    private enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var isCorner: Bool { rawValue % 2 == 0 }
        var opposite: Handle { Handle(rawValue: (rawValue + 4) % 8)! }
        /// Unit position in the layer's box (0…1 on each axis).
        var unit: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 0)
            case .top: CGPoint(x: 0.5, y: 0)
            case .topRight: CGPoint(x: 1, y: 0)
            case .right: CGPoint(x: 1, y: 0.5)
            case .bottomRight: CGPoint(x: 1, y: 1)
            case .bottom: CGPoint(x: 0.5, y: 1)
            case .bottomLeft: CGPoint(x: 0, y: 1)
            case .left: CGPoint(x: 0, y: 0.5)
            }
        }
        var cornerIndex: Int { rawValue / 2 }
    }

    var body: some View {
        let t = model.displayTransform(for: size)
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(.rect)
                .gesture(moveGesture(t))
            if let layer = model.selectedLayer, let local = Self.localBounds(layer, assets: model.document.assets) {
                let quad = Self.corners(layer, local: local).map { $0.applying(t) }
                Path { $0.addLines(quad); $0.closeSubpath() }
                    .stroke(Hero.accent, lineWidth: 1)
                    .allowsHitTesting(false)
                if !layer.isLocked {
                    let top = midpoint(quad[0], quad[1])
                    let knob = rotationKnob(quad: quad)
                    Path { $0.move(to: top); $0.addLine(to: knob) }.stroke(Hero.accent, lineWidth: 1).allowsHitTesting(false)
                    Circle().fill(.white).overlay(Circle().strokeBorder(Hero.accent, lineWidth: 1))
                        .frame(width: 12, height: 12)
                        .frame(width: 20, height: 20).contentShape(.rect)
                        .position(knob)
                        .gesture(rotateGesture(t, local: local))
                        .pointerStyle(.grabIdle)
                        .accessibilityLabel("Rotate layer")
                    ForEach(Handle.allCases, id: \.self) { handle in
                        RoundedRectangle(cornerRadius: 2).fill(.white)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Hero.accent, lineWidth: 1))
                            .frame(width: 8, height: 8)
                            .frame(width: 16, height: 16).contentShape(.rect)
                            .position(position(of: handle, quad: quad))
                            .gesture(scaleGesture(handle, t, local: local))
                            .pointerStyle(.frameResize(position: Self.frameEdge(handle)))
                            .accessibilityLabel("Resize layer")
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .allowsHitTesting(active)
        .accessibilityHidden(!active)
    }

    private static let space = "transform"

    // MARK: Geometry

    /// The layer's own box (before its transform), or `nil` for layers that cover the document.
    static func localBounds(_ layer: Layer, assets: any AssetStore) -> CGRect? {
        let local = LayerCompositor.contentBounds(layer.content, assets: assets)
        if !local.isNull { return local }
        if case .group = layer.content {
            var plain = layer
            plain.transform = .identity
            plain.perspective = nil
            let b = LayerCompositor.bounds(of: plain, assets: assets)
            return b.isNull ? nil : b
        }
        return nil
    }

    /// Source-pixel corners (tl, tr, br, bl), through the perspective quad when there is one.
    static func corners(_ layer: Layer, local: CGRect) -> [CGPoint] {
        if let q = layer.perspective { return [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft] }
        return [
            CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.minY),
            CGPoint(x: local.maxX, y: local.maxY), CGPoint(x: local.minX, y: local.maxY),
        ].map { $0.applying(layer.transform) }
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    private func position(of handle: Handle, quad: [CGPoint]) -> CGPoint {
        handle.isCorner ? quad[handle.cornerIndex] : midpoint(quad[handle.cornerIndex], quad[(handle.cornerIndex + 1) % 4])
    }

    /// 24 points beyond the top edge, away from the box's middle.
    private func rotationKnob(quad: [CGPoint]) -> CGPoint {
        let top = midpoint(quad[0], quad[1]), bottom = midpoint(quad[3], quad[2])
        let dx = top.x - bottom.x, dy = top.y - bottom.y
        let length = max(0.001, hypot(dx, dy))
        return CGPoint(x: top.x + dx / length * 24, y: top.y + dy / length * 24)
    }

    private static func frameEdge(_ handle: Handle) -> FrameResizePosition {
        switch handle {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .right: .trailing
        case .bottomRight: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .left: .leading
        }
    }

    // MARK: Gestures

    private func moveGesture(_ t: CGAffineTransform) -> some Gesture {
        let inverse = t.inverted()
        let pixelsPerPoint = 1 / max(0.0001, hypot(t.a, t.b))
        return DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let from = value.startLocation.applying(inverse), to = value.location.applying(inverse)
                if start == nil {
                    guard let layer = pick(at: from), !layer.isLocked else { return }
                    start = layer
                }
                guard let layer = start else { return }
                var dx = to.x - from.x, dy = to.y - from.y
                let box = LayerCompositor.bounds(of: layer, assets: model.document.assets)
                if !box.isNull, !NSEvent.modifierFlags.contains(.command) {
                    let tolerance = 6 * pixelsPerPoint
                    dx += GuideSnapping.offset([box.minX + dx, box.midX + dx, box.maxX + dx], to: model.snapTargets(.vertical), tolerance: tolerance) ?? 0
                    dy += GuideSnapping.offset([box.minY + dy, box.midY + dy, box.maxY + dy], to: model.snapTargets(.horizontal), tolerance: tolerance) ?? 0
                }
                let shift = CGAffineTransform(translationX: dx, y: dy)
                model.updateLayer(layer.id, "Move Layer", live: true) {
                    $0.transform = layer.transform.concatenating(shift)
                    $0.perspective = layer.perspective.map { q in
                        Quad(
                            topLeft: q.topLeft.applying(shift), topRight: q.topRight.applying(shift), bottomRight: q.bottomRight.applying(shift),
                            bottomLeft: q.bottomLeft.applying(shift))
                    }
                }
            }
            .onEnded { _ in
                if start != nil { model.endLive("Move Layer") }
                start = nil
            }
    }

    /// Select the topmost visible layer under `point` (source pixels), or the selected one
    /// when it's there; clicking empty space deselects.
    private func pick(at point: CGPoint) -> Layer? {
        let assets = model.document.assets
        func hit(_ layer: Layer) -> Bool {
            guard layer.isVisible else { return false }
            let b = LayerCompositor.bounds(of: layer, assets: assets)
            return !b.isNull && b.contains(point)
        }
        if let selected = model.selectedLayer, hit(selected) { return selected }
        let found = model.recipe.layers.last(where: hit)
        model.layerState.selectedID = found?.id
        return found
    }

    private func scaleGesture(_ handle: Handle, _ t: CGAffineTransform, local: CGRect) -> some Gesture {
        let inverse = t.inverted()
        return DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let layer = start ?? model.selectedLayer else { return }
                start = layer
                let pointer = value.location.applying(inverse)
                if handle.isCorner, NSEvent.modifierFlags.contains(.command) || layer.perspective != nil {
                    var q = Self.corners(layer, local: local)
                    q[handle.cornerIndex] = pointer
                    model.updateLayer(layer.id, "Perspective", live: true) {
                        $0.perspective = Quad(topLeft: q[0], topRight: q[1], bottomRight: q[2], bottomLeft: q[3])
                    }
                    return
                }
                func at(_ u: CGPoint) -> CGPoint { CGPoint(x: local.minX + u.x * local.width, y: local.minY + u.y * local.height) }
                let anchor = at(handle.opposite.unit), grip = at(handle.unit)
                let p = pointer.applying(layer.transform.inverted())
                func factor(_ a: Double, _ g: Double, _ v: Double) -> Double {
                    abs(g - a) < 0.001 ? 1 : (v - a) / (g - a)
                }
                var sx = handle.unit.x == 0.5 ? 1 : factor(anchor.x, grip.x, p.x)
                var sy = handle.unit.y == 0.5 ? 1 : factor(anchor.y, grip.y, p.y)
                if handle.isCorner, !NSEvent.modifierFlags.contains(.shift) {
                    let s = abs(sx) > abs(sy) ? sx : sy
                    (sx, sy) = (s, s)
                }
                sx = abs(sx) < 0.01 ? 0.01 : sx
                sy = abs(sy) < 0.01 ? 0.01 : sy
                let scale = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
                    .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                    .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
                model.updateLayer(layer.id, "Scale Layer", live: true) { $0.transform = scale.concatenating(layer.transform) }
            }
            .onEnded { _ in
                if start != nil { model.endLive(start?.perspective != nil || NSEvent.modifierFlags.contains(.command) ? "Perspective" : "Scale Layer") }
                start = nil
            }
    }

    private func rotateGesture(_ t: CGAffineTransform, local: CGRect) -> some Gesture {
        let inverse = t.inverted()
        return DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let layer = start ?? model.selectedLayer else { return }
                start = layer
                let c = CGPoint(x: local.midX, y: local.midY).applying(layer.transform)
                let a = value.startLocation.applying(inverse), b = value.location.applying(inverse)
                var angle = atan2(b.y - c.y, b.x - c.x) - atan2(a.y - c.y, a.x - c.x)
                if NSEvent.modifierFlags.contains(.shift) { angle = (angle / (.pi / 12)).rounded() * .pi / 12 }
                let rotation = CGAffineTransform(translationX: -c.x, y: -c.y)
                    .concatenating(CGAffineTransform(rotationAngle: angle))
                    .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
                model.updateLayer(layer.id, "Rotate Layer", live: true) { $0.transform = layer.transform.concatenating(rotation) }
            }
            .onEnded { _ in
                if start != nil { model.endLive("Rotate Layer") }
                start = nil
            }
    }
}
