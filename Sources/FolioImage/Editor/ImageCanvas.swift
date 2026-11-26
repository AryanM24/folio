import FolioKit
import SwiftUI

/// The scrollable, zoomable image on a neutral backdrop, with the crop, markup and
/// Live Text layers sized exactly to the picture.
struct ImageCanvas: View {
    let model: ImageEditorModel
    @State private var pinchBase: Double?
    @State private var visible: CGRect = .zero
    @State private var position = ScrollPosition()

    var body: some View {
        GeometryReader { geo in
            let size = imageSize
            ScrollView([.horizontal, .vertical]) {
                picture(size: size)
                    .padding(ImageEditorModel.canvasInsets)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .scrollPosition($position)
            .scrollIndicators(.automatic)
            .onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, rect in visible = rect }
            .onChange(of: geo.size, initial: true) { model.viewportSize = geo.size }
            .onChange(of: model.zoomScale) { old, new in keepCenter(old: old, new: new, viewport: geo.size) }
        }
        .background(Hero.backgroundSecondary)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? model.zoomScale
                    pinchBase = base
                    model.setZoom(base * value.magnification)
                }
                .onEnded { _ in pinchBase = nil }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image")
    }

    /// Display size in points.
    private var imageSize: CGSize {
        let px = model.displayPixelSize
        let z = model.zoomScale
        return CGSize(width: (px.width * z).rounded(), height: (px.height * z).rounded())
    }

    @ViewBuilder private func picture(size: CGSize) -> some View {
        ZStack {
            if model.source.hasAlpha || model.recipe.removeBackground {
                Checkerboard().frame(width: size.width, height: size.height)
            }
            if let image = shownImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(model.zoomScale >= 2 ? .none : .high)
                    .frame(width: size.width, height: size.height)
                    .accessibilityLabel(model.comparing ? "Original image" : "Edited image")
            } else {
                ProgressView().controlSize(.small)
            }
            if !model.comparing {
                MarkupOverlay(model: model, size: size)
                if model.tab == .crop {
                    CropOverlay(model: model, size: size)
                }
                if model.liveTextEnabled, let image = model.preview {
                    LiveTextOverlay(image: image)
                        .frame(width: size.width, height: size.height)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .modifier(PictureShadow())
    }

    /// The preview, or the untouched original while comparing.
    private var shownImage: CGImage? {
        model.comparing ? model.source.proxy : model.preview
    }

    /// Zoom around the middle of what's visible instead of jumping to the corner.
    private func keepCenter(old: Double, new: Double, viewport: CGSize) {
        guard old > 0, visible.width > 0 else { return }
        let ratio = new / old
        let center = CGPoint(x: visible.midX * ratio, y: visible.midY * ratio)
        position.scrollTo(point: CGPoint(x: max(0, center.x - viewport.width / 2), y: max(0, center.y - viewport.height / 2)))
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

/// The transparency pattern behind cut-outs and PNGs with alpha.
private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            // Bigger tiles on huge canvases keep this to a few thousand rectangles.
            let tile = max(10, (size.width * size.height / 20_000).squareRoot())
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Hero.surface))
            var path = Path()
            for row in 0..<Int((size.height / tile).rounded(.up)) {
                for col in 0..<Int((size.width / tile).rounded(.up)) where (row + col) % 2 == 0 {
                    path.addRect(CGRect(x: Double(col) * tile, y: Double(row) * tile, width: tile, height: tile))
                }
            }
            ctx.fill(path, with: .color(Hero.default))
        }
        .accessibilityHidden(true)
    }
}
