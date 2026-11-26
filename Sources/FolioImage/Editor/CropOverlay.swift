import FolioKit
import SwiftUI

/// The interactive crop box: dimmed outside, rule-of-thirds grid inside, eight
/// handles, and drag-to-move. Each drag is one undo step.
struct CropOverlay: View {
    let model: ImageEditorModel
    let size: CGSize
    @State private var dragStart: CGRect?
    @State private var dragging = false

    private var crop: CGRect {
        let c = model.recipe.crop
        return CGRect(x: c.minX * size.width, y: c.minY * size.height, width: c.width * size.width, height: c.height * size.height)
    }

    var body: some View {
        let box = crop
        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop (even-odd fill punches the hole).
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(box)
            }
            .fill(Color.black.opacity(dragging ? 0.35 : 0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            thirds(in: box)

            Rectangle()
                .fill(Color.white.opacity(0.001))  // hit area for moving
                .frame(width: box.width, height: box.height)
                .overlay(Rectangle().strokeBorder(.white, lineWidth: 1))
                .offset(x: box.minX, y: box.minY)
                .gesture(drag(.move))
                .pointerStyle(.grabIdle)
                .accessibilityLabel("Crop area")
                .accessibilityHint("Drag to move the crop.")

            ForEach(CropMath.Handle.allCases.filter { $0 != .move }, id: \.self) { handle in
                HandleView(handle: handle)
                    .position(position(of: handle, in: box))
                    .gesture(drag(handle))
                    .accessibilityLabel("Crop handle")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(Hero.animation, value: dragging)
    }

    private func thirds(in box: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = box.minX + box.width * Double(i) / 3
                let y = box.minY + box.height * Double(i) / 3
                p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(dragging ? 0.7 : 0.35), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    private func position(of handle: CropMath.Handle, in box: CGRect) -> CGPoint {
        let x: Double = handle.movesLeft ? box.minX : handle.movesRight ? box.maxX : box.midX
        let y: Double = handle.movesTop ? box.minY : handle.movesBottom ? box.maxY : box.midY
        return CGPoint(x: x, y: y)
    }

    private func drag(_ handle: CropMath.Handle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? model.recipe.crop
                dragStart = start
                dragging = true
                let delta = CGSize(
                    width: value.translation.width / max(1, size.width), height: value.translation.height / max(1, size.height))
                let ratio = model.cropAspect.ratio(original: model.geometry.canvasSize)
                let canvas = model.geometry.canvasSize
                model.live {
                    $0.crop = CropMath.drag(handle, from: start, by: delta, ratio: ratio, canvas: canvas)
                    // A fixed output size would distort a new crop shape.
                    if handle != .move { $0.resize = nil }
                }
            }
            .onEnded { _ in
                dragStart = nil
                dragging = false
                model.endLive("Crop")
            }
    }
}

/// Corner handles are L-shaped brackets, edge handles short bars, as in Photos.
private struct HandleView: View {
    let handle: CropMath.Handle

    var body: some View {
        let arm: Double = 18, weight: Double = 4
        Path { p in
            switch handle {
            case .topLeft: p.move(to: CGPoint(x: 0, y: arm)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: arm, y: 0))
            case .topRight: p.move(to: CGPoint(x: -arm, y: 0)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: 0, y: arm))
            case .bottomLeft: p.move(to: CGPoint(x: 0, y: -arm)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: arm, y: 0))
            case .bottomRight: p.move(to: CGPoint(x: -arm, y: 0)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: 0, y: -arm))
            case .top, .bottom: p.move(to: CGPoint(x: -arm / 2, y: 0)); p.addLine(to: CGPoint(x: arm / 2, y: 0))
            case .left, .right: p.move(to: CGPoint(x: 0, y: -arm / 2)); p.addLine(to: CGPoint(x: 0, y: arm / 2))
            case .move: break
            }
        }
        .offsetBy(dx: 22, dy: 22)
        .stroke(.white, style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
        .shadow(color: .black.opacity(0.35), radius: 1.5)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
}
