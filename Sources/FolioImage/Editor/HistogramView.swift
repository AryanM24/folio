import CoreImage
import FolioKit
import SwiftUI

/// The live RGB and luminance histogram under the inspector tabs, from the preview.
struct HistogramView: View {
    let model: ImageEditorModel
    @State private var histogram = Histogram()

    var body: some View {
        Canvas { ctx, size in
            func path(_ bins: [Float], closed: Bool) -> Path {
                var p = Path()
                guard bins.count > 1 else { return p }
                let step = size.width / CGFloat(bins.count - 1)
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() { p.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(v)))) }
                if closed {
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                }
                return p
            }
            ctx.fill(path(histogram.luminance, closed: true), with: .color(Hero.muted.opacity(0.25)))
            for (bins, channel) in [(histogram.red, ToneChannel.red), (histogram.green, .green), (histogram.blue, .blue)] {
                ctx.stroke(path(bins, closed: false), with: .color(channel.color.opacity(0.6)), lineWidth: 1)
            }
        }
        .frame(height: 64)
        .padding(.vertical, 4)
        .background(Hero.surfaceSecondary, in: .rect(cornerRadius: Hero.Radius.lg))
        .task(id: model.preview.map(ObjectIdentifier.init)) {
            guard let image = model.preview else {
                histogram = Histogram()
                return
            }
            // Coalesce bursts of preview frames during a drag.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            histogram = await Self.compute(image)
        }
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(summary)
    }

    /// Where most of the image's tones sit, for VoiceOver.
    private var summary: String {
        let l = histogram.luminance
        guard l.count >= 3 else { return "Empty" }
        let third = l.count / 3
        let thirds = [l[..<third], l[third..<2 * third], l[(2 * third)...]].map { $0.reduce(0, +) }
        let names = ["Mostly shadows", "Mostly midtones", "Mostly highlights"]
        return names[thirds.indices.max { thirds[$0] < thirds[$1] } ?? 1]
    }

    @concurrent nonisolated private static func compute(_ image: CGImage) async -> Histogram {
        Histogram.compute(CIImage(cgImage: image))
    }
}
