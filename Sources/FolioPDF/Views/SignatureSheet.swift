import FolioKit
import SwiftUI

/// Draw a signature once with the trackpad or mouse. It is saved for reuse (see
/// ``SignatureStore``) and placed on the visible page.
struct SignatureSheet: View {
    let model: PDFEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var drawing = false

    /// Points on screen; the saved image is rendered at 3x for print.
    private let padSize = CGSize(width: 480, height: 180)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Draw your signature").font(.system(size: 15, weight: .semibold))
                Text("Folio keeps it on this Mac and reuses it in every PDF.")
                    .font(.system(size: 13))
                    .foregroundStyle(Hero.muted)
            }
            pad
            HStack {
                Button("Clear") { strokes = [] }
                    .buttonStyle(.hero(.tertiary))
                    .disabled(strokes.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.hero(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Save and Insert", action: save)
                    .buttonStyle(.hero(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(strokes.isEmpty)
            }
        }
        .padding(24)
        .background(Hero.surface)
    }

    /// White paper with a baseline, whatever the window appearance.
    private var pad: some View {
        Canvas { context, _ in
            for stroke in strokes { context.stroke(path(stroke), with: .color(.black), style: Self.ink) }
        }
        .frame(width: padSize.width, height: padSize.height)
        .background {
            ZStack(alignment: .bottomLeading) {
                Color.white
                Rectangle().fill(Color.black.opacity(0.15)).frame(height: 1).padding(.horizontal, 24).padding(.bottom, 44)
                if strokes.isEmpty {
                    Text("Sign here").font(.system(size: 13)).foregroundStyle(.black.opacity(0.35)).padding(24)
                }
            }
        }
        .clipShape(.rect(cornerRadius: Hero.Radius.xl))
        .overlay { RoundedRectangle(cornerRadius: Hero.Radius.xl).strokeBorder(Hero.border) }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !drawing {
                        strokes.append([drag.startLocation])
                        drawing = true
                    }
                    strokes[strokes.count - 1].append(drag.location)
                }
                .onEnded { _ in drawing = false }
        )
        .accessibilityLabel("Signature pad")
        .accessibilityHint("Drag to draw your signature")
    }

    private static let ink = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)

    private func path(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }

    /// Renders only the ink (transparent background), cropped to what was drawn.
    private func save() {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
            let minY = all.map(\.y).min(), let maxY = all.map(\.y).max()
        else { return }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -4, dy: -4)
        let renderer = ImageRenderer(
            content: Canvas { context, _ in
                context.translateBy(x: -crop.minX, y: -crop.minY)
                for stroke in strokes { context.stroke(path(stroke), with: .color(.black), style: Self.ink) }
            }.frame(width: crop.width, height: crop.height))
        renderer.scale = 3
        guard let image = renderer.cgImage else { return }
        do {
            try SignatureStore.save(image)
            dismiss()
            model.insertSignature()
        } catch {
            model.show(error, title: "Couldn't save the signature")
        }
    }
}
