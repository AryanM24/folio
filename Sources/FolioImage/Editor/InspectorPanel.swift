import FolioKit
import SwiftUI

/// The right-hand inspector: Adjust, Filters, Crop and Markup tabs on a Hero overlay.
struct InspectorPanel: View {
    @Bindable var model: ImageEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HeroTabs(InspectorTab.allCases.map { ($0, $0.title, nil) }, selection: $model.tab)
                .padding(12)
            Rectangle().fill(Hero.separator).frame(height: 1)
            ScrollView {
                Group {
                    switch model.tab {
                    case .adjust: AdjustPanel(model: model)
                    case .filters: FiltersPanel(model: model)
                    case .crop: CropPanel(model: model)
                    case .markup: MarkupPanel(model: model)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.never)
            Rectangle().fill(Hero.separator).frame(height: 1)
            Button("Reset All", systemImage: "arrow.uturn.backward") { model.resetAll() }
                .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
                .disabled(!model.isEdited)
                .help("Undo every edit and go back to the original ⇧⌘R")
                .padding(12)
        }
        .heroOverlay(cornerRadius: Hero.Radius.xxxl)
    }
}

/// A Hero slider that resets to its default on double-click and turns a drag into
/// one undo step.
struct RecipeSlider: View {
    let model: ImageEditorModel
    let title: String
    let keyPath: WritableKeyPath<EditRecipe, Double>
    let range: ClosedRange<Double>
    var step = 1.0
    var defaultValue = 0.0
    var format: (Double) -> String = { value in
        let n = Int(value.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }

    var body: some View {
        HeroSlider(title, value: model.binding(keyPath, action: title), in: range, step: step, format: format) { editing in
            model.sliderEditing(editing, action: title)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                // After the slider's own drag ends, so the reset is the last word.
                DispatchQueue.main.async { model.commit("Reset \(title)") { $0[keyPath: keyPath] = defaultValue } }
            }
        )
        .help("Double-click to reset")
        .accessibilityAction(named: "Reset") { model.commit("Reset \(title)") { $0[keyPath: keyPath] = defaultValue } }
    }
}
