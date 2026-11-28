import FolioKit
import SwiftUI

/// Input and output black, white and gamma, per channel.
struct LevelsEditor: View {
    let model: ImageEditorModel
    @State private var channel: ToneChannel = .rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeroTabs(ToneChannel.allCases.map { ($0, $0.title, nil) }, selection: $channel)
            let levels = \EditRecipe.tone.levels[channel]
            let eight: (Double) -> String = { "\(Int(($0 * 255).rounded()))" }
            RecipeSlider(
                model: model, title: "Input Black", keyPath: levels.appending(path: \.inputBlack), range: 0...0.99, step: 1 / 255,
                format: eight)
            RecipeSlider(
                model: model, title: "Input White", keyPath: levels.appending(path: \.inputWhite), range: 0.01...1, step: 1 / 255,
                defaultValue: 1, format: eight)
            RecipeSlider(
                model: model, title: "Gamma", keyPath: levels.appending(path: \.gamma), range: 0.1...3, step: 0.01, defaultValue: 1,
                format: { String(format: "%.2f", $0) })
            RecipeSlider(
                model: model, title: "Output Black", keyPath: levels.appending(path: \.outputBlack), range: 0...1, step: 1 / 255,
                format: eight)
            RecipeSlider(
                model: model, title: "Output White", keyPath: levels.appending(path: \.outputWhite), range: 0...1, step: 1 / 255,
                defaultValue: 1, format: eight)
        }
    }
}
