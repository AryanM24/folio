import AppKit
import FolioKit
import SwiftUI

/// Markup tools, color and width, and editing the selected item.
struct MarkupPanel: View {
    @Bindable var model: ImageEditorModel
    @FocusState private var textFocused: Bool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    /// The ink palette plus white, as stored colors.
    private static let palette: [(Color, RGBA)] = ColorSwatches.ink.compactMap { color in
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (color, RGBA(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            InspectorSection("Tool") {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(MarkupTool.allCases) { tool in
                        Button { model.markupTool = tool } label: { Label(tool.title, systemImage: tool.symbol) }
                            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, fullWidth: true, isSelected: model.markupTool == tool))
                            .help(tool.title)
                            .accessibilityAddTraits(model.markupTool == tool ? .isSelected : [])
                    }
                }
            }
            InspectorSection("Color") {
                ColorSwatches(Self.palette.map(\.0), selection: colorBinding)
            }
            HeroSlider("Line width", value: widthBinding, in: 1...40, format: { "\(Int($0)) pt" }) { editing in
                if !editing { model.endLive("Line Width") }
            }
            if let item = model.selectedMarkup {
                selection(item)
            } else {
                Text(model.markupTool == .select ? "Click a shape to select it, then drag to move." : "Drag on the image to draw. Choose Select to move or delete shapes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Hero.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: model.focusMarkupText) {
            if model.focusMarkupText { textFocused = true; model.focusMarkupText = false }
        }
        .onChange(of: textFocused) {
            model.isEditingText = textFocused
            // Typing is live; leaving the field makes the whole edit one undo step.
            if !textFocused { model.endLive("Edit Text") }
        }
    }

    @ViewBuilder private func selection(_ item: MarkupItem) -> some View {
        InspectorSection("Selected \(item.kind.rawValue)") {
            if item.kind == .text {
                TextField("Text", text: Binding(
                    get: { model.selectedMarkup?.text ?? "" },
                    set: { text in model.updateSelectedMarkup("Edit Text", live: true) { $0.text = text } }
                ), axis: .vertical)
                .textFieldStyle(.hero)
                .focused($textFocused)
                .accessibilityLabel("Text")
                HeroSlider("Size", value: Binding(
                    get: { (model.selectedMarkup?.fontSize ?? 24) / pixelsPerPoint },
                    set: { size in model.updateSelectedMarkup("Text Size", live: true) { $0.fontSize = size * pixelsPerPoint } }
                ), in: 8...144, format: { "\(Int($0)) pt" }) { editing in
                    if !editing { model.endLive("Text Size") }
                }
            }
            Button("Delete", systemImage: "trash") { model.deleteSelectedMarkup() }
                .buttonStyle(.hero(.dangerSoft, size: .sm))
                .help("Delete the selected shape ⌫")
        }
    }

    /// Source pixels per screen point at the current zoom.
    private var pixelsPerPoint: Double {
        let size = model.displayPixelSize
        let t = model.displayTransform(for: CGSize(width: size.width * model.zoomScale, height: size.height * model.zoomScale))
        return 1 / max(0.0001, hypot(t.a, t.b))
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let current = model.selectedMarkup?.color ?? model.markupColor
                return Self.palette.first { $0.1 == current }?.0 ?? Color(cgColor: current.cgColor)
            },
            set: { color in
                if let match = Self.palette.first(where: { $0.0 == color }) { model.setMarkupColor(match.1) }
            }
        )
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: {
                if let item = model.selectedMarkup, item.kind != .text {
                    return (item.lineWidth / pixelsPerPoint / (item.kind == .highlighter ? 4 : 1)).rounded()
                }
                return model.markupWidth
            },
            set: { width in
                model.markupWidth = width
                guard let item = model.selectedMarkup, item.kind != .text else { return }
                let px = width * pixelsPerPoint * (item.kind == .highlighter ? 4 : 1)
                model.updateSelectedMarkup("Line Width", live: true) { $0.lineWidth = px }
            }
        )
    }
}
