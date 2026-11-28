import FolioKit
import SwiftUI

/// The right-hand inspector: Adjust, Tone, Filters and Layer tabs on a Hero overlay.
/// The crop tool and the Markup panel take the body over, with a Done button.
struct InspectorPanel: View {
    @Bindable var model: ImageEditorModel

    var body: some View {
        VStack(spacing: 0) {
            header.padding(12)
            Rectangle().fill(Hero.separator).frame(height: 1)
            ScrollView {
                Group {
                    switch model.tab {
                    case .adjust: AdjustPanel(model: model)
                    case .tone:
                        VStack(alignment: .leading, spacing: 24) {
                            HistogramView(model: model)
                            TonePanel(model: model)
                        }
                    case .filters: FiltersPanel(model: model)
                    case .layer: LayerInspector(model: model)
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

    @ViewBuilder private var header: some View {
        if InspectorTab.strip.contains(model.tab) {
            HeroTabs(InspectorTab.strip.map { ($0, $0.title, nil) }, selection: $model.tab)
        } else {
            HStack {
                Text(model.tab.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Hero.foreground)
                Spacer()
                Button("Done") { model.tab == .crop ? (model.tool = .move) : (model.tab = .adjust) }
                    .buttonStyle(.hero(.tertiary, size: .sm))
            }
            .frame(height: 36)
            .padding(.leading, 4)
        }
    }
}

/// The selected layer's properties: name, opacity, blend, content, mask and effects.
/// Sliders turn a drag into one undo step.
struct LayerInspector: View {
    let model: ImageEditorModel
    @State private var name = ""
    @State private var text = ""
    /// The slider being dragged, so keyboard changes commit straight away instead.
    @State private var dragging: String?

    var body: some View {
        if let layer = model.selectedLayer {
            VStack(alignment: .leading, spacing: 24) {
                InspectorSection("Layer") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.hero)
                        .onSubmit { model.updateLayer(layer.id, "Rename Layer") { $0.name = name } }
                        .accessibilityLabel("Layer name")
                    slider("Opacity", layer, \.opacity, 0...1, percent)
                    slider("Fill", layer, \.fillOpacity, 0...1, percent)
                    Menu {
                        BlendModeItems(model: model, layer: layer)
                    } label: {
                        Text("Blend: \(layer.blend.title)")
                    }
                    .menuStyle(.button).buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
                    .accessibilityLabel("Blend mode \(layer.blend.title)")
                    Toggle("Clip to layer below", isOn: toggle(layer, \.clipsToBelow, "Clipping Mask")).toggleStyle(.hero)
                    Toggle("Locked", isOn: Binding(get: { layer.isLocked }, set: { model.setLayerLocked(layer.id, $0) })).toggleStyle(.hero)
                }
                content(layer)
                transform(layer)
                mask(layer)
                effects(layer)
            }
            .onAppear { sync(layer) }
            .onChange(of: layer.id) { sync(layer) }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("No layer selected")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Hero.foreground)
                Text("Pick one in the Layers list, or add one to start.")
                    .font(.system(size: 12)).foregroundStyle(Hero.muted)
                HStack(spacing: 6) {
                    Button("Text") { model.addTextLayer() }
                    Button("Shape") { model.addShapeLayer() }
                    Button("Paint") { model.addPaintLayer() }
                }
                .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
            }
        }
    }

    private func sync(_ layer: Layer) {
        name = layer.name
        if case .text(let spec) = layer.content { text = spec.string }
    }

    // MARK: Sections

    @ViewBuilder private func content(_ layer: Layer) -> some View {
        switch layer.content {
        case .text(let spec):
            InspectorSection("Text") {
                TextField("Text", text: $text, axis: .vertical)
                    .textFieldStyle(.hero)
                    .lineLimit(1...4)
                    .onSubmit { setText(layer, spec) }
                    .onChange(of: text) { setText(layer, spec) }
                    .accessibilityLabel("Text")
                slider("Size", layer, \.textSize, 4...1000, { "\(Int($0)) px" })
                colorRow("Color", spec.runs.first?.color ?? RGBA(red: 0, green: 0, blue: 0)) { color in
                    model.updateLayer(layer.id, "Text Color") { $0.textColor = color }
                }
                HeroTabs(
                    TextSpec.Alignment.allCases.map { ($0, $0.rawValue.capitalized, nil) },
                    selection: Binding(get: { spec.alignment }, set: { a in model.updateLayer(layer.id, "Align Text") { $0.textAlignment = a } }))
            }
        case .shape(let spec):
            InspectorSection("Shape") {
                if case .solid(let color) = spec.fill {
                    colorRow("Fill", color) { c in model.updateLayer(layer.id, "Shape Fill") { $0.shapeFill = c } }
                }
                colorRow("Stroke", spec.stroke?.color ?? RGBA(red: 0, green: 0, blue: 0)) { c in
                    model.updateLayer(layer.id, "Shape Stroke") { $0.shapeStroke = c }
                }
                slider("Stroke width", layer, \.strokeWidth, 0...200, { "\(Int($0)) px" })
            }
        case .fill(.solid(let color)):
            InspectorSection("Fill") {
                colorRow("Color", color) { c in model.updateLayer(layer.id, "Fill Color") { $0.content = .fill(.solid(c)) } }
            }
        case .adjustment(let spec):
            InspectorSection("Adjustment") {
                switch spec {
                case .blur: slider("Radius", layer, \.adjustmentAmount, 0...200, { "\(Int($0)) px" })
                case .pixelate: slider("Block size", layer, \.adjustmentAmount, 2...200, { "\(Int($0)) px" })
                case .filter(let preset, _): slider(preset.title, layer, \.adjustmentAmount, 0...1, percent)
                case .adjustments, .tone:
                    Text("Edits made in Adjust and Tone apply to the photo. This layer keeps its own settings.")
                        .font(.system(size: 12)).foregroundStyle(Hero.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private func transform(_ layer: Layer) -> some View {
        if TransformHandles.localBounds(layer, assets: model.document.assets) != nil {
            InspectorSection("Transform") {
                let t = layer.transform
                LabeledContent("Position") {
                    Text("\(Int(t.tx.rounded())), \(Int(t.ty.rounded())) px").monospacedDigit()
                }
                LabeledContent("Scale") {
                    Text("\(Int((hypot(t.a, t.b) * 100).rounded()))%").monospacedDigit()
                }
                LabeledContent("Rotation") {
                    Text("\(Int((atan2(t.b, t.a) * 180 / .pi).rounded()))°").monospacedDigit()
                }
                Button("Reset transform") {
                    model.updateLayer(layer.id, "Reset Transform") {
                        $0.transform = CGAffineTransform(translationX: t.tx, y: t.ty)
                        $0.perspective = nil
                    }
                }
                .buttonStyle(.hero(.ghost, size: .sm))
                .disabled(t.isTranslationOnly && layer.perspective == nil)
            }
            .font(.system(size: 13))
            .foregroundStyle(Hero.foreground)
        }
    }

    @ViewBuilder private func mask(_ layer: Layer) -> some View {
        InspectorSection("Mask") {
            if let mask = layer.mask {
                Toggle("Enabled", isOn: Binding(get: { mask.isEnabled }, set: { on in model.updateLayer(layer.id, "Mask Enabled") { $0.mask?.isEnabled = on } }))
                    .toggleStyle(.hero)
                Toggle("Inverted", isOn: Binding(get: { mask.inverted }, set: { on in model.updateLayer(layer.id, "Invert Mask") { $0.mask?.inverted = on } }))
                    .toggleStyle(.hero)
                slider("Feather", layer, \.maskFeather, 0...250, { "\(Int($0)) px" })
                slider("Density", layer, \.maskDensity, 0...1, percent)
                Button("Remove mask", systemImage: "trash") { model.updateLayer(layer.id, "Remove Mask") { $0.mask = nil } }
                    .buttonStyle(.hero(.dangerSoft, size: .sm))
            } else {
                Button("Add mask from selection") { model.addMaskFromSelection() }
                    .buttonStyle(.hero(.tertiary, size: .sm, fullWidth: true))
                    .disabled(model.selectionState.spec == nil)
                    .help("Make a selection first, then use it as this layer's mask")
            }
        }
    }

    @ViewBuilder private func effects(_ layer: Layer) -> some View {
        InspectorSection("Effects") {
            effectToggle("Drop shadow", layer, .dropShadow(ShadowEffect()))
            effectToggle("Stroke", layer, .stroke(StrokeEffect()))
            effectToggle("Outer glow", layer, .outerGlow(GlowEffect()))
        }
    }

    private func effectToggle(_ title: String, _ layer: Layer, _ effect: LayerEffect) -> some View {
        let index = layer.effects.firstIndex { $0.kind == effect.kind }
        return Toggle(
            title,
            isOn: Binding(
                get: { index != nil },
                set: { on in
                    model.updateLayer(layer.id, on ? "Add \(title)" : "Remove \(title)") {
                        if on { $0.effects.append(effect) } else { $0.effects.removeAll { $0.kind == effect.kind } }
                    }
                })
        )
        .toggleStyle(.hero)
    }

    // MARK: Controls

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func slider(
        _ title: String, _ layer: Layer, _ keyPath: WritableKeyPath<Layer, Double>, _ range: ClosedRange<Double>,
        _ format: @escaping (Double) -> String
    ) -> some View {
        let step = range.upperBound <= 1 ? 0.01 : 1
        return HeroSlider(
            title,
            value: Binding(
                get: { layer[keyPath: keyPath] },
                set: { value in model.updateLayer(layer.id, title, live: dragging == title) { $0[keyPath: keyPath] = value } }),
            in: range, step: step, format: format
        ) { editing in
            if editing {
                dragging = title
            } else if dragging == title {
                dragging = nil
                model.endLive(title)
            }
        }
    }

    private func toggle(_ layer: Layer, _ keyPath: WritableKeyPath<Layer, Bool>, _ action: String) -> Binding<Bool> {
        Binding(get: { layer[keyPath: keyPath] }, set: { on in model.updateLayer(layer.id, action) { $0[keyPath: keyPath] = on } })
    }

    private func colorRow(_ title: String, _ color: RGBA, set: @escaping (RGBA) -> Void) -> some View {
        ColorPicker(
            title,
            selection: Binding(
                get: { Color(cgColor: color.cgColor) },
                set: { c in
                    guard let s = NSColor(c).usingColorSpace(.sRGB) else { return }
                    set(RGBA(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent, alpha: s.alphaComponent))
                })
        )
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Hero.foreground)
    }

    private func setText(_ layer: Layer, _ spec: TextSpec) {
        guard text != spec.string, !text.isEmpty else { return }
        model.updateLayer(layer.id, "Edit Text") { l in
            guard case .text(var s) = l.content else { return }
            var run = s.runs.first ?? TextRun(text: "")
            run.text = text
            s.runs = [run]
            l.content = .text(s)
            l.name = String(text.prefix(30))
        }
    }
}

/// The 27 blend modes in Photoshop's groups, checking the layer's.
struct BlendModeItems: View {
    let model: ImageEditorModel
    let layer: Layer

    private static let groups: [[Layer.BlendMode]] = [
        [.normal, .dissolve], [.darken, .multiply, .colorBurn, .linearBurn, .darkerColor],
        [.lighten, .screen, .colorDodge, .linearDodge, .lighterColor],
        [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix],
        [.difference, .exclusion, .subtract, .divide], [.hue, .saturation, .color, .luminosity],
    ]

    var body: some View {
        ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group) { mode in
                Toggle(mode.title, isOn: Binding(get: { layer.blend == mode }, set: { _ in model.setLayerBlend(layer.id, mode) }))
            }
        }
    }
}

// Inspector accessors for nested layer values, so sliders can bind with key paths.
nonisolated extension Layer {
    var textSize: Double {
        get { if case .text(let s) = content { s.runs.first?.size ?? 48 } else { 0 } }
        set { if case .text(var s) = content { s.runs = s.runs.map { var r = $0; r.size = newValue; return r }; content = .text(s) } }
    }
    var textColor: RGBA {
        get { if case .text(let s) = content { s.runs.first?.color ?? RGBA(red: 0, green: 0, blue: 0) } else { RGBA(red: 0, green: 0, blue: 0) } }
        set { if case .text(var s) = content { s.runs = s.runs.map { var r = $0; r.color = newValue; return r }; content = .text(s) } }
    }
    var textAlignment: TextSpec.Alignment {
        get { if case .text(let s) = content { s.alignment } else { .left } }
        set { if case .text(var s) = content { s.alignment = newValue; content = .text(s) } }
    }
    var shapeFill: RGBA {
        get { if case .shape(let s) = content, case .solid(let c) = s.fill { c } else { .white } }
        set { if case .shape(var s) = content { s.fill = .solid(newValue); content = .shape(s) } }
    }
    var shapeStroke: RGBA {
        get { if case .shape(let s) = content { s.stroke?.color ?? RGBA(red: 0, green: 0, blue: 0) } else { RGBA(red: 0, green: 0, blue: 0) } }
        set { if case .shape(var s) = content { s.stroke = s.stroke ?? StrokeSpec(width: 0); s.stroke?.color = newValue; content = .shape(s) } }
    }
    var strokeWidth: Double {
        get { if case .shape(let s) = content { s.stroke?.width ?? 0 } else { 0 } }
        set {
            guard case .shape(var s) = content else { return }
            if newValue <= 0 { s.stroke = nil } else { s.stroke = s.stroke ?? StrokeSpec(); s.stroke?.width = newValue }
            content = .shape(s)
        }
    }
    /// Blur radius, pixelate size or filter strength.
    var adjustmentAmount: Double {
        get {
            switch content {
            case .adjustment(.blur(let r)): r
            case .adjustment(.pixelate(let s)): s
            case .adjustment(.filter(_, let strength)): strength
            default: 0
            }
        }
        set {
            switch content {
            case .adjustment(.blur): content = .adjustment(.blur(radius: newValue))
            case .adjustment(.pixelate): content = .adjustment(.pixelate(size: newValue))
            case .adjustment(.filter(let p, _)): content = .adjustment(.filter(p, strength: newValue))
            default: break
            }
        }
    }
    var maskFeather: Double {
        get { mask?.feather ?? 0 }
        set { mask?.feather = newValue }
    }
    var maskDensity: Double {
        get { mask?.density ?? 1 }
        set { mask?.density = newValue }
    }
}

nonisolated extension LayerEffect {
    /// Which effect this is, ignoring its settings.
    var kind: Int {
        switch self {
        case .dropShadow: 0
        case .stroke: 1
        case .outerGlow: 2
        }
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
