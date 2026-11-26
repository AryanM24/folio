import FolioKit
import SwiftUI

/// Auto-enhance plus the light, color and detail sliders.
struct AdjustPanel: View {
    let model: ImageEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Toggle("Auto-enhance", isOn: Binding(get: { model.recipe.autoEnhance != nil }, set: { _ in model.toggleAutoEnhance() }))
                .toggleStyle(.hero)
                .help("Let macOS balance exposure, color and contrast ⌥⌘E")
            ForEach(Adjustment.Section.allCases, id: \.self) { section in
                InspectorSection(LocalizedStringKey(section.rawValue)) {
                    VStack(spacing: 16) {
                        ForEach(Adjustment.allCases.filter { $0.section == section }) { adjustment in
                            RecipeSlider(model: model, title: adjustment.title,
                                         keyPath: \.adjustments[adjustment], range: adjustment.range)
                        }
                    }
                }
            }
            Button("Reset Adjustments") { model.resetAdjustments() }
                .buttonStyle(.hero(.ghost, size: .sm))
                .disabled(model.recipe.adjustments.isNeutral && model.recipe.autoEnhance == nil)
        }
    }
}

/// The preset grid, each tile showing the current edit under that look.
struct FiltersPanel: View {
    let model: ImageEditorModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(columns: columns, spacing: 12) {
                tile(nil, title: "Original", image: model.filterBase)
                ForEach(FilterPreset.allCases) { preset in
                    tile(preset, title: preset.title, image: model.filterThumbnails[preset])
                }
            }
            if model.recipe.filter != nil {
                RecipeSlider(model: model, title: "Strength", keyPath: \.filterStrength, range: 0...1, step: 0.01,
                             defaultValue: 1, format: { "\(Int(($0 * 100).rounded()))%" })
            }
        }
        .onAppear { model.refreshThumbnailsIfVisible() }
    }

    private func tile(_ preset: FilterPreset?, title: String, image: CGImage?) -> some View {
        let selected = model.recipe.filter == preset
        return Button {
            model.commit(preset.map { "Filter \($0.title)" } ?? "Remove Filter") { $0.filter = preset }
        } label: {
            VStack(spacing: 6) {
                // Fill the tile without letting the image widen the grid column.
                Hero.default
                    .frame(height: 76)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        }
                    }
                    .clipShape(.rect(cornerRadius: Hero.Radius.xl))
                    .overlay {
                        RoundedRectangle(cornerRadius: Hero.Radius.xl)
                            .strokeBorder(selected ? Hero.accent : Hero.border, lineWidth: selected ? 2 : 0.5)
                    }
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Hero.foreground : Hero.muted)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
