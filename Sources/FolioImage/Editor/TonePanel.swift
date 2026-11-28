import CoreImage
import FolioKit
import SwiftUI
import UniformTypeIdentifiers

/// The Tone tab: curves, levels, HSL, color balance, white balance, LUT and presets.
struct TonePanel: View {
    let model: ImageEditorModel
    @State private var band: HueBand = .red
    @State private var range: TonalRange = .midtones
    @State private var mixerOutput: ToneChannel = .red

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PresetsMenu(model: model)
            InspectorSection("White Balance") { whiteBalance }
            InspectorSection("Curves") { CurvesEditor(model: model) }
            InspectorSection("Levels") { LevelsEditor(model: model) }
            InspectorSection("HSL") { hsl }
            InspectorSection("Color Balance") { colorBalance }
            InspectorSection("Channel Mixer") { channelMixer }
            InspectorSection("LUT") { lut }
            Button("Reset Tone") { model.commit("Reset Tone") { $0.tone = ToneSpec() } }
                .buttonStyle(.hero(.ghost, size: .sm))
                .disabled(model.recipe.tone.isIdentity)
        }
        .task { await ToneRenderer.warmUp() }
    }

    // MARK: White balance

    @ViewBuilder private var whiteBalance: some View {
        RecipeSlider(
            model: model, title: "Temperature", keyPath: \.tone.balance.temperature, range: 2000...15000, step: 50, defaultValue: 6500,
            format: { "\(Int($0)) K" })
        RecipeSlider(model: model, title: "Tint", keyPath: \.tone.balance.tint, range: -150...150)
        HStack(spacing: 6) {
            Button("Pick Neutral", systemImage: "eyedropper") { model.tool = .eyedropper }
                .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true, isSelected: model.tool == .eyedropper))
                .help("Click something white or gray in the photo to make it neutral")
            Button("Auto", systemImage: "wand.and.stars") { model.setWhiteBalance(sampleAt: nil) }
                .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
                .help("Balance the whole photo to neutral gray")
        }
    }

    // MARK: HSL

    @ViewBuilder private var hsl: some View {
        HStack(spacing: 0) {
            ForEach(HueBand.allCases) { b in
                Button {
                    band = b
                } label: {
                    Circle().fill(b.color).frame(width: 18, height: 18)
                        .overlay { Circle().strokeBorder(Hero.foreground, lineWidth: band == b ? 2 : 0).padding(-3) }
                        .overlay(alignment: .topTrailing) {
                            if !(model.recipe.tone.hsl[b]?.isNeutral ?? true) {
                                Circle().fill(Hero.foreground).frame(width: 5, height: 5).offset(x: 3, y: -3)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(b.title)
                .accessibilityLabel(b.title)
                .accessibilityAddTraits(band == b ? .isSelected : [])
            }
        }
        let shift = \EditRecipe.tone[band: band]
        RecipeSlider(model: model, title: "\(band.title) Hue", keyPath: shift.appending(path: \.hue), range: -100...100)
        RecipeSlider(model: model, title: "\(band.title) Saturation", keyPath: shift.appending(path: \.saturation), range: -100...100)
        RecipeSlider(model: model, title: "\(band.title) Luminance", keyPath: shift.appending(path: \.luminance), range: -100...100)
    }

    // MARK: Color balance

    @ViewBuilder private var colorBalance: some View {
        HeroTabs(TonalRange.allCases.map { ($0, $0.title, nil) }, selection: $range)
        let balance: WritableKeyPath<EditRecipe, ColorBalance> = \.tone.colorBalance
        let shift = balance.appending(path: range.keyPath)
        RecipeSlider(model: model, title: "Cyan – Red", keyPath: shift.appending(path: \.cyanRed), range: -100...100)
        RecipeSlider(model: model, title: "Magenta – Green", keyPath: shift.appending(path: \.magentaGreen), range: -100...100)
        RecipeSlider(model: model, title: "Yellow – Blue", keyPath: shift.appending(path: \.yellowBlue), range: -100...100)
        Toggle(
            "Preserve luminosity",
            isOn: Binding(
                get: { model.recipe.tone.colorBalance.preserveLuminosity },
                set: { on in model.commit("Preserve Luminosity") { $0.tone.colorBalance.preserveLuminosity = on } })
        )
        .toggleStyle(.hero)
    }

    // MARK: Channel mixer

    @ViewBuilder private var channelMixer: some View {
        let mixer = model.recipe.tone.mixer
        Toggle(
            "Monochrome",
            isOn: Binding(
                get: { mixer.monochrome },
                set: { on in model.commit("Monochrome Mixer") { $0.tone.mixer.monochrome = on } })
        )
        .toggleStyle(.hero)
        if !mixer.monochrome {
            HeroTabs([ToneChannel.red, .green, .blue].map { ($0, $0.title, nil) }, selection: $mixerOutput)
        }
        let output = mixer.monochrome ? ToneChannel.red : mixerOutput
        let mixerPath: WritableKeyPath<EditRecipe, ChannelMixer> = \.tone.mixer
        let row = mixerPath.appending(path: Self.row(output))
        let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
        ForEach([ToneChannel.red, .green, .blue]) { input in
            RecipeSlider(
                model: model, title: input.title, keyPath: row.appending(path: Self.input(input)), range: -2...2, step: 0.01,
                defaultValue: input == output ? 1 : 0, format: percent)
        }
        RecipeSlider(model: model, title: "Constant", keyPath: row.appending(path: \.constant), range: -1...1, step: 0.01, format: percent)
    }

    private static func row(_ channel: ToneChannel) -> WritableKeyPath<ChannelMixer, ChannelMixer.Row> {
        switch channel {
        case .green: \.green
        case .blue: \.blue
        default: \.red
        }
    }

    private static func input(_ channel: ToneChannel) -> WritableKeyPath<ChannelMixer.Row, Double> {
        switch channel {
        case .green: \.green
        case .blue: \.blue
        default: \.red
        }
    }

    // MARK: LUT

    @ViewBuilder private var lut: some View {
        if let ref = model.recipe.tone.lut {
            HStack {
                Label(ref.name, systemImage: "cube")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Hero.foreground)
                    .lineLimit(1)
                Spacer()
                Button("Remove LUT", systemImage: "xmark") { model.commit("Remove LUT") { $0.tone.lut = nil } }
                    .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                    .help("Remove the LUT")
            }
            RecipeSlider(
                model: model, title: "Strength", keyPath: \.tone.lutStrength, range: 0...1, step: 0.01, defaultValue: 1,
                format: { "\(Int(($0 * 100).rounded()))%" })
        }
        Button(model.recipe.tone.lut == nil ? "Load LUT…" : "Replace LUT…", systemImage: "square.and.arrow.down") { loadLUT() }
            .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
            .help("Apply a .cube or .3dl color lookup table")
    }

    private func loadLUT() {
        Task {
            let types = ["cube", "3dl"].compactMap { UTType(filenameExtension: $0) }
            guard let url = await Exporter.pick(types: types, multiple: false).first else { return }
            do {
                let data = try Data(contentsOf: url)
                _ = try CubeLUT(data: data)
                let id = try model.document.assets.put(data)
                let name = url.deletingPathExtension().lastPathComponent
                model.commit("Load LUT") { $0.tone.lut = LUTRef(asset: id, name: name) }
            } catch {
                model.show(error, title: "Couldn't use “\(url.lastPathComponent)”")
            }
        }
    }
}

/// The three ranges of the color balance panel.
enum TonalRange: String, CaseIterable, Identifiable {
    case shadows, midtones, highlights
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var keyPath: WritableKeyPath<ColorBalance, ColorShift> {
        switch self {
        case .shadows: \.shadows
        case .midtones: \.midtones
        case .highlights: \.highlights
        }
    }
}

extension HueBand {
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .red: Color(hue: 0, saturation: 0.8, brightness: 0.9)
        case .orange: Color(hue: 30 / 360, saturation: 0.8, brightness: 0.95)
        case .yellow: Color(hue: 55 / 360, saturation: 0.8, brightness: 0.95)
        case .green: Color(hue: 120 / 360, saturation: 0.7, brightness: 0.75)
        case .aqua: Color(hue: 180 / 360, saturation: 0.7, brightness: 0.8)
        case .blue: Color(hue: 225 / 360, saturation: 0.75, brightness: 0.9)
        case .purple: Color(hue: 270 / 360, saturation: 0.6, brightness: 0.85)
        case .magenta: Color(hue: 310 / 360, saturation: 0.65, brightness: 0.9)
        }
    }
}

nonisolated extension ToneSpec {
    /// The LUT's strength, for the slider (no LUT reads as full strength and writes nothing).
    var lutStrength: Double {
        get { lut?.strength ?? 1 }
        set { lut?.strength = newValue }
    }
}

// MARK: - White balance eyedropper

extension ImageEditorModel {
    /// Set white balance so the color around `point` (source pixels, top-left origin)
    /// becomes neutral; `nil` balances the whole image. The canvas calls this when the
    /// eyedropper clicks while the Tone tab is showing.
    func setWhiteBalance(sampleAt point: CGPoint?) {
        let (source, recipe, assets) = (self.source, self.recipe, document.assets)
        Task {
            guard let wb = await Self.neutralWhiteBalance(source: source, recipe: recipe, assets: assets, point: point) else {
                showToast("That spot is too dark to balance on")
                return
            }
            commit("White Balance") { $0.tone.whiteBalance = wb }
            if tool == .eyedropper { tool = .move }
        }
    }

    /// Samples the image as it looks before tone (white balance comes first), 5 × 5
    /// proxy pixels around `point`.
    @concurrent nonisolated private static func neutralWhiteBalance(
        source: SourceImage, recipe: EditRecipe, assets: any AssetStore, point: CGPoint?
    ) async -> WhiteBalance? {
        var base = recipe
        base.tone = ToneSpec()
        base.filter = nil
        let scale = source.proxyScale
        guard let input = try? RenderPipeline.input(for: source, raw: base.raw, scale: scale) else { return nil }
        let image = RenderPipeline.filtered(input, recipe: base, assets: assets, scale: scale, mask: nil)
        let rect =
            point.map { CGRect(x: $0.x * scale - 2.5, y: image.extent.maxY - $0.y * scale - 2.5, width: 5, height: 5) } ?? image.extent
        return ToneRenderer.whiteBalance(neutralizing: image, in: rect)
    }
}
