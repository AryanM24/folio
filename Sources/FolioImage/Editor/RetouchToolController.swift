import AppKit
import FolioKit
import SwiftUI

/// Turns drags on the canvas into retouch strokes while the Retouch tool is active.
///
/// Shows the brush as a circle under the pointer. Drag to brush; ⇧-drag a rectangle
/// for blur, pixelate and redact; click for spot heal and red-eye. Clone and heal copy
/// from a source point set with ⌥-click, marked with a crosshair that follows the brush.
struct RetouchToolController: View {
    let model: ImageEditorModel
    /// The picture frame in points, as for `MarkupOverlay`.
    let size: CGSize

    @State private var hover: CGPoint?
    /// The stroke being drawn, in source pixels.
    @State private var points: [CGPoint] = []
    @State private var rectStart: CGPoint?
    @State private var settingSource = false

    private var state: RetouchState { model.retouchState }
    private var interactive: Bool { model.tool == .retouch }

    var body: some View {
        let transform = model.displayTransform(for: size)
        Canvas { ctx, _ in
            let outline = Color.white.opacity(0.9)
            let shadow = Color.black.opacity(0.5)
            func ring(_ center: CGPoint, _ radius: Double) {
                let path = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                ctx.stroke(path, with: .color(shadow), lineWidth: 3)
                ctx.stroke(path, with: .color(outline), lineWidth: 1)
            }
            if let start = rectStart, let last = points.last {
                let rect = CGRect(origin: start.applying(transform), size: .zero).union(
                    CGRect(origin: last.applying(transform), size: .zero))
                ctx.stroke(Path(rect), with: .color(Hero.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            } else if points.count > 1 {
                var path = Path()
                path.addLines(points.map { $0.applying(transform) })
                ctx.stroke(
                    path, with: .color(Hero.accent.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 2 * state.radius, lineCap: .round, lineJoin: .round))
            }
            if let hover, interactive, rectStart == nil { ring(hover, state.radius) }
            if state.tool.needsSource, let source = state.sourcePoint {
                // While brushing, the crosshair moves with the brush, as in Photoshop.
                var marker = source
                if let first = points.first, let last = points.last {
                    marker = CGPoint(x: source.x + last.x - first.x, y: source.y + last.y - first.y)
                }
                let p = marker.applying(transform)
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 7, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 7, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 7)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 7))
                ctx.stroke(cross, with: .color(shadow), lineWidth: 3)
                ctx.stroke(cross, with: .color(outline), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(.rect)
        .allowsHitTesting(interactive)
        .onContinuousHover { phase in
            if case .active(let location) = phase { hover = location } else { hover = nil }
        }
        .pointerStyle(.rectSelection)
        .gesture(drag(transform: transform))
        .accessibilityHidden(!interactive)
        .accessibilityLabel("Retouch canvas")
        .accessibilityHint(hint)
    }

    private var hint: String {
        switch state.tool {
        case .clone, .heal: "Option-click to pick a source, then drag to \(state.tool.title.lowercased())."
        case .spotHeal, .redEye: "Click or drag over the spot to fix."
        case .remove: "Drag over the object to remove."
        case .blur, .pixelate, .redact: "Drag to brush, or Shift-drag a rectangle, to \(state.tool.title.lowercased())."
        }
    }

    private func drag(transform: CGAffineTransform) -> some Gesture {
        let inverse = transform.inverted()
        // Source pixels per screen point, for the brush radius and point spacing.
        let pixelsPerPoint = 1 / max(0.0001, hypot(transform.a, transform.b))
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                hover = value.location
                let point = value.location.applying(inverse)
                if points.isEmpty {
                    let flags = NSEvent.modifierFlags
                    settingSource = flags.contains(.option) && state.tool.needsSource
                    rectStart = flags.contains(.shift) && state.tool.allowsRect ? point : nil
                    points = [point]
                    return
                }
                if rectStart != nil {
                    points = [points[0], point]
                } else if let last = points.last, hypot(last.x - point.x, last.y - point.y) >= max(1, state.radius * pixelsPerPoint / 4) {
                    // Spacing of a quarter radius keeps strokes light and still smooth.
                    points.append(point)
                }
            }
            .onEnded { value in
                defer { points = []; rectStart = nil; settingSource = false }
                guard let first = points.first else { return }
                let last = value.location.applying(inverse)
                if settingSource {
                    state.sourcePoint = first
                    return
                }
                if state.tool.needsSource && state.sourcePoint == nil {
                    model.showToast("Option-click to choose where to \(state.tool == .clone ? "clone" : "heal") from")
                    return
                }
                let area: RetouchStroke.Area
                if let start = rectStart {
                    let rect = CGRect(origin: start, size: .zero).union(CGRect(origin: last, size: .zero))
                    guard rect.width >= 1, rect.height >= 1 else { return }
                    area = .rect(rect)
                } else {
                    area = .brush(points: points, radius: state.radius * pixelsPerPoint)
                }
                let offset = state.sourcePoint.map { CGSize(width: $0.x - first.x, height: $0.y - first.y) }
                model.addRetouchStroke(
                    RetouchStroke(
                        tool: state.tool, area: area, hardness: state.hardness, opacity: state.opacity,
                        sourceOffset: state.tool.needsSource ? offset : nil, sampleAllLayers: state.sampleAllLayers,
                        amount: state.tool == .redEye ? 1 : 0))
            }
    }
}
