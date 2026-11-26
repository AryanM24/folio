import FolioKit
import PDFKit
import SwiftUI

/// The floating inspector: style of the selected annotation, or of the active tool's
/// next annotation. Only the controls that apply to that kind are shown.
struct AnnotationInspector: View {
    @Bindable var model: PDFEditorModel
    @FocusState private var textFocused: Bool

    private var annotation: PDFAnnotation? { model.selectedAnnotation }
    private var kind: AnnotationKind? { annotation.map(AnnotationKind.init) }

    private var title: String { kind?.title ?? model.tool.title }
    private var showsText: Bool { kind?.hasText ?? false }
    private var showsColor: Bool { kind?.hasColor ?? model.tool.hasColor }
    private var showsStroke: Bool { kind?.hasStroke ?? model.tool.hasStroke }
    private var showsFont: Bool { kind?.isFreeText ?? model.tool.hasFont }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Hero.foreground)
                Spacer()
                if annotation != nil {
                    Button("Done", systemImage: "xmark") { model.select(nil) }
                        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                        .help("Deselect (Esc)")
                }
            }
            if showsText, let annotation {
                InspectorSection("Text") {
                    TextEditor(text: Binding(get: { model.selectionText }, set: { model.setText($0, of: annotation) }))
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($textFocused)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(height: 72)
                        .background(Hero.field, in: .rect(cornerRadius: Hero.Radius.xl))
                        .overlay {
                            RoundedRectangle(cornerRadius: Hero.Radius.xl)
                                .strokeBorder(textFocused ? Hero.accent : Hero.border, lineWidth: textFocused ? 2 : 1)
                        }
                        .accessibilityLabel("\(title) text")
                }
            }
            if showsColor {
                InspectorSection("Color") {
                    ColorSwatches(selection: styleBinding(\.color))
                }
            }
            if showsStroke {
                slider("Stroke", \.lineWidth, in: 1...24, format: { "\(Int($0)) pt" })
            }
            if showsFont {
                slider("Font size", \.fontSize, in: 8...72, format: { "\(Int($0)) pt" })
            }
            slider("Opacity", \.opacity, in: 0.1...1, step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" })
            if let annotation {
                Button("Delete \(AnnotationKind(annotation).title)", systemImage: "trash", role: .destructive) {
                    model.remove(annotation)
                }
                .buttonStyle(.hero(.dangerSoft, size: .sm, fullWidth: true))
            }
        }
        .padding(16)
        .frame(width: 232)
        .heroOverlay(cornerRadius: Hero.Radius.xxxl)
        .onChange(of: model.focusTextRequest) { textFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) inspector")
    }

    private func styleBinding<Value>(_ keyPath: WritableKeyPath<AnnotationStyle, Value>) -> Binding<Value> {
        Binding(
            get: { model.activeStyle[keyPath: keyPath] },
            set: { value in
                var style = model.activeStyle
                style[keyPath: keyPath] = value
                model.updateStyle(style)
            }
        )
    }

    /// A Hero slider whose drag is one undo step.
    private func slider(
        _ label: String, _ keyPath: WritableKeyPath<AnnotationStyle, Double>, in range: ClosedRange<Double>, step: Double = 1,
        format: @escaping (Double) -> String
    ) -> some View {
        HeroSlider(label, value: styleBinding(keyPath), in: range, step: step, format: format) { editing in
            if editing { model.beginStyleEdit() } else { model.endStyleEdit() }
        }
    }
}
