import FolioKit
import SwiftUI

/// The curve graph with draggable points, per channel.
///
/// Click to add a point, drag to move it, drag it off the graph or press Delete to
/// remove it. Arrow keys nudge the selected point. The end points can move but not go.
struct CurvesEditor: View {
    let model: ImageEditorModel
    @State private var channel: ToneChannel = .rgb
    /// The points while a drag is in progress; the recipe re-sorts and normalizes.
    @State private var dragPoints: [CGPoint]?
    @State private var dragIndex: Int?
    @State private var selected: Int?
    @FocusState private var focused: Bool

    private static let hitRadius: CGFloat = 10
    private static let removeDistance: CGFloat = 24

    private var points: [CGPoint] {
        if let dragPoints { return dragPoints }
        let stored = model.recipe.tone.curves[channel]
        return stored.isEmpty ? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)] : stored
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HeroTabs(ToneChannel.allCases.map { ($0, $0.title, nil) }, selection: $channel)
                Spacer(minLength: 0)
                Button("Reset Curve", systemImage: "arrow.uturn.backward") {
                    model.commit("Reset Curve") { $0.tone.curves[channel] = [] }
                    selected = nil
                }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .disabled(model.recipe.tone.curves[channel].isEmpty)
                .help("Reset this channel’s curve")
            }
            GeometryReader { geo in
                graph(size: geo.size)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .onChange(of: channel) { selected = nil }
    }

    private func graph(size: CGSize) -> some View {
        let pts = points
        let curve = ToneCurve(pts)
        let color = channel.color
        return Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            for i in 1..<4 {
                let f = CGFloat(i) / 4
                var grid = Path()
                grid.move(to: CGPoint(x: rect.width * f, y: 0))
                grid.addLine(to: CGPoint(x: rect.width * f, y: rect.height))
                grid.move(to: CGPoint(x: 0, y: rect.height * f))
                grid.addLine(to: CGPoint(x: rect.width, y: rect.height * f))
                ctx.stroke(grid, with: .color(Hero.separator), lineWidth: 1)
            }
            var diagonal = Path()
            diagonal.move(to: CGPoint(x: 0, y: rect.height))
            diagonal.addLine(to: CGPoint(x: rect.width, y: 0))
            ctx.stroke(diagonal, with: .color(Hero.border), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var line = Path()
            for i in 0...128 {
                let x = Double(i) / 128
                let p = CGPoint(x: x * rect.width, y: (1 - curve(x)) * rect.height)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            ctx.stroke(line, with: .color(color), lineWidth: 1.5)
            for (i, p) in pts.enumerated() {
                let c = CGPoint(x: p.x * rect.width, y: (1 - p.y) * rect.height)
                let dot = Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
                ctx.fill(dot, with: .color(i == selected ? color : Hero.surface))
                ctx.stroke(dot, with: .color(color), lineWidth: 1.5)
            }
        }
        .background(Hero.surfaceSecondary, in: .rect(cornerRadius: Hero.Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: Hero.Radius.lg).strokeBorder(Hero.border, lineWidth: 0.5) }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag($0, size: size) }
                .onEnded { endDrag($0, size: size) }
        )
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let selected else { return .ignored }
            remove(selected)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard let selected else { return .ignored }
            let step = press.modifiers.contains(.shift) ? 0.05 : 0.01
            let (dx, dy): (Double, Double) =
                switch press.key {
                case .upArrow: (0, step)
                case .downArrow: (0, -step)
                case .leftArrow: (-step, 0)
                default: (step, 0)
                }
            var pts = points
            pts[selected] = clamped(CGPoint(x: pts[selected].x + dx, y: pts[selected].y + dy), at: selected, in: pts)
            model.commit("Curves") { $0.tone.curves[channel] = pts }
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("\(channel.title) curve")
        .accessibilityValue(pts.map { "\(Int(($0.x * 255).rounded())) to \(Int(($0.y * 255).rounded()))" }.joined(separator: ", "))
        .accessibilityHint("Click to add a point, drag to move it, drag it off the graph to remove it")
    }

    // MARK: Editing

    private func unit(_ location: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: location.x / max(1, size.width), y: 1 - location.y / max(1, size.height))
    }

    /// Keep x between the neighbors so the order (and the dragged index) never changes.
    private func clamped(_ p: CGPoint, at index: Int, in pts: [CGPoint]) -> CGPoint {
        let lo = index > 0 ? pts[index - 1].x + 0.01 : 0
        let hi = index < pts.count - 1 ? pts[index + 1].x - 0.01 : 1
        return CGPoint(x: min(hi, max(lo, p.x)), y: min(1, max(0, p.y)))
    }

    private func isOutside(_ location: CGPoint, _ size: CGSize) -> Bool {
        let d = Self.removeDistance
        return location.x < -d || location.y < -d || location.x > size.width + d || location.y > size.height + d
    }

    private func drag(_ value: DragGesture.Value, size: CGSize) {
        focused = true
        var pts = points
        if dragIndex == nil {
            let start = value.startLocation
            let hit = pts.indices.min { a, b in distance(pts[a], start, size) < distance(pts[b], start, size) }
            if let hit, distance(pts[hit], start, size) <= Self.hitRadius {
                dragIndex = hit
            } else {
                let p = unit(start, size)
                let index = pts.firstIndex { $0.x > p.x } ?? pts.count
                // Not too close to a neighbor, so the new point can be told apart.
                guard index > 0, index < pts.count, p.x - pts[index - 1].x > 0.02, pts[index].x - p.x > 0.02 else { return }
                pts.insert(p, at: index)
                dragIndex = index
            }
            selected = dragIndex
        }
        guard let index = dragIndex else { return }
        if isOutside(value.location, size), index != 0, index != pts.count - 1 {
            selected = nil
        } else {
            pts[index] = clamped(unit(value.location, size), at: index, in: pts)
            selected = index
        }
        dragPoints = pts
        let live = selected == nil ? removing(index, from: pts) : pts
        model.live { $0.tone.curves[channel] = live }
    }

    private func endDrag(_ value: DragGesture.Value, size: CGSize) {
        defer {
            dragPoints = nil
            dragIndex = nil
        }
        guard dragIndex != nil else { return }
        model.endLive("Curves")
    }

    private func removing(_ index: Int, from pts: [CGPoint]) -> [CGPoint] {
        var out = pts
        out.remove(at: index)
        return out
    }

    private func remove(_ index: Int) {
        let pts = points
        guard index > 0, index < pts.count - 1 else { return }
        model.commit("Remove Curve Point") { $0.tone.curves[channel] = removing(index, from: pts) }
        selected = nil
    }

    private func distance(_ p: CGPoint, _ location: CGPoint, _ size: CGSize) -> CGFloat {
        hypot(p.x * size.width - location.x, (1 - p.y) * size.height - location.y)
    }
}

extension ToneChannel {
    var title: String {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }

    /// The histogram colors, so a channel reads the same everywhere.
    var color: Color {
        switch self {
        case .rgb: Hero.foreground
        case .red: Hero.danger
        case .green: Hero.success
        case .blue: Hero.accent
        }
    }
}
