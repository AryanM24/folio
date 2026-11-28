import FolioKit
import SwiftUI

/// The floating top bar: the active tool's options, then compare, zoom, info and export.
struct ContextBar: View {
    @Bindable var model: ImageEditorModel
    @State private var showInfo = false
    @State private var showExport = false

    var body: some View {
        HeroToolbar {
            options
            HeroToolbarDivider()
            CompareButton(model: model)
            zoomMenu
            button("Info", "info.circle", help: "Image info ⌘I", selected: showInfo) { showInfo.toggle() }
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { InfoPopover(model: model) }
            button("Export", "square.and.arrow.up", help: "Export, copy or share ⇧⌘E", selected: showExport) { showExport.toggle() }
                .popover(isPresented: $showExport, arrowEdge: .bottom) { ExportPopover(model: model) }
        }
        .onChange(of: model.requestedPopover, initial: true) {
            switch model.requestedPopover {
            case .info: showInfo = true
            case .export: showExport = true
            case nil: break
            }
            model.requestedPopover = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.tool.title) options")
    }

    // MARK: Tool options

    @ViewBuilder private var options: some View {
        switch model.tool {
        case .move: moveOptions
        case .select: selectOptions
        case .crop: cropOptions
        case .retouch: retouchOptions
        case .brush, .eraser: brushOptions
        case .text:
            colorWell
            OptionsButton(title: "Text size", summary: "\(Int(model.options.fontSize)) pt") {
                HeroSlider("Size", value: $model.options.fontSize, in: 6...300, format: { "\(Int($0)) pt" })
            }
        case .shape:
            variantMenu("Shape", model.options.shape.title, model.options.shape.symbol) {
                ForEach(ShapeKind.allCases) { kind in Button(kind.title, systemImage: kind.symbol) { model.options.shape = kind } }
            }
            colorWell
        case .gradient:
            variantMenu("Gradient", model.options.gradient.rawValue.capitalized, "circle.lefthalf.filled") {
                ForEach(GradientSpec.Kind.allCases, id: \.self) { kind in Button(kind.rawValue.capitalized) { model.options.gradient = kind } }
            }
            colorWell
        case .eyedropper:
            colorWell
            Text(model.tab == .tone ? "Click something neutral" : model.options.color.hex)
                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                .foregroundStyle(Hero.muted)
                .padding(.horizontal, 8)
        case .hand, .zoom:
            if model.tool == .zoom {
                button("Zoom In", "plus.magnifyingglass", help: "Clicks zoom in", selected: !model.options.zoomOut) { model.options.zoomOut = false }
                button("Zoom Out", "minus.magnifyingglass", help: "Clicks zoom out", selected: model.options.zoomOut) { model.options.zoomOut = true }
                HeroToolbarDivider()
            }
            textButton("Fit", help: "Zoom to fit ⌘9") { model.zoomToFit() }
            textButton("100%", help: "Actual size ⌘0") { model.actualSize() }
            textButton("Selection", help: "Zoom to the selection or layer ⌥⌘0") { model.zoomToSelection() }
        }
    }

    @ViewBuilder private var moveOptions: some View {
        button("Rotate Left", "rotate.left", help: "Rotate left ⌘L") { model.rotateLeft() }
        button("Rotate Right", "rotate.right", help: "Rotate right ⌘R") { model.rotateRight() }
        button("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal") {
            model.flipHorizontal()
        }
        HeroToolbarDivider()
        button("Auto-Enhance", "wand.and.stars", help: "Auto-enhance ⌥⌘E", selected: model.recipe.autoEnhance != nil) {
            model.toggleAutoEnhance()
        }
        button("Remove Background", "person.and.background.dotted", help: "Remove background ⇧⌘K", selected: model.recipe.removeBackground) {
            model.toggleRemoveBackground()
        }
        button("Live Text", "text.viewfinder", help: "Select text in the image ⌥⌘T", selected: model.liveTextEnabled) {
            model.liveTextEnabled.toggle()
        }
    }

    @ViewBuilder private var selectOptions: some View {
        let state = model.selectionState
        variantMenu("Selection tool", state.tool.title, state.tool.symbol) {
            ForEach(SelectionTool.allCases) { tool in Button(tool.title, systemImage: tool.symbol) { state.tool = tool } }
        }
        button("Add to Selection", "plus.square", help: "Add to the selection (hold ⇧)", selected: state.mode == .add) { state.mode = .add }
        button("Subtract from Selection", "minus.square", help: "Subtract from the selection (hold ⌥)", selected: state.mode == .subtract) {
            state.mode = .subtract
        }
        button("Intersect with Selection", "square.on.square", help: "Intersect with the selection (hold ⇧⌥)", selected: state.mode == .intersect) {
            state.mode = .intersect
        }
        switch state.tool {
        case .wand:
            OptionsButton(title: "Tolerance", summary: "\(Int((state.wandTolerance * 100).rounded()))%") {
                HeroSlider("Tolerance", value: Bindable(state).wandTolerance, in: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })
                Toggle("Contiguous", isOn: Bindable(state).contiguous).toggleStyle(.hero)
                Toggle("Sample all layers", isOn: Bindable(state).sampleAllLayers).toggleStyle(.hero)
            }
        case .colorRange:
            OptionsButton(title: "Fuzziness", summary: "\(Int((state.fuzziness * 100).rounded()))%") {
                HeroSlider("Fuzziness", value: Bindable(state).fuzziness, in: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })
            }
        case .subject:
            textButton("All subjects", help: "Select every subject ⌥⌘S") { model.selectSubject(at: nil) }
        case .sky:
            textButton("Select sky", help: "Select the sky") { model.selectSky() }
        default: EmptyView()
        }
        HeroToolbarDivider()
        button("Invert Selection", "circle.lefthalf.filled.inverse", help: "Invert ⇧⌘I") { model.invertSelection() }
            .disabled(state.spec == nil)
        button("Deselect", "xmark.square", help: "Deselect ⌘D") { model.deselect() }
            .disabled(state.spec == nil)
        button("Add Mask from Selection", "square.dashed.inset.filled", help: "Mask the selected layer with the selection") {
            model.addMaskFromSelection()
        }
        .disabled(state.spec == nil || model.selectedLayer == nil)
    }

    @ViewBuilder private var cropOptions: some View {
        button("Rotate Left", "rotate.left", help: "Rotate left ⌘L") { model.rotateLeft() }
        button("Rotate Right", "rotate.right", help: "Rotate right ⌘R") { model.rotateRight() }
        button("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal") {
            model.flipHorizontal()
        }
        button("Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertical") { model.flipVertical() }
        HeroToolbarDivider()
        textButton("Reset", help: "Reset crop and rotation") { model.resetCrop() }
        Button("Done") { model.tool = .move }
            .buttonStyle(.hero(.primary, size: .sm))
            .keyboardShortcut(.defaultAction)
            .help("Finish cropping ↩")
    }

    @ViewBuilder private var retouchOptions: some View {
        let state = model.retouchState
        variantMenu("Retouch tool", state.tool.title, state.tool.symbol) {
            ForEach(RetouchStroke.Tool.allCases) { tool in Button(tool.title, systemImage: tool.symbol) { state.tool = tool } }
        }
        OptionsButton(title: "Brush", summary: "\(Int(state.radius * 2)) pt") {
            HeroSlider("Size", value: Bindable(state).radius, in: 1...250, format: { "\(Int($0 * 2)) pt" })
            HeroSlider("Hardness", value: Bindable(state).hardness, in: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })
            HeroSlider("Opacity", value: Bindable(state).opacity, in: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })
            Toggle("Sample all layers", isOn: Bindable(state).sampleAllLayers).toggleStyle(.hero)
        }
        if model.selectionState.spec != nil {
            textButton("Fill selection", help: "Apply the tool to the selection") { model.retouchSelection() }
        }
        switch state.tool {
        case .redEye: textButton("Fix all", help: "Find and fix red eyes") { model.fixRedEye() }
        case .redact:
            Menu("Auto-redact") {
                Button("Faces") { model.autoRedact(faces: true, text: false, barcodes: false) }
                Button("Text") { model.autoRedact(faces: false, text: true, barcodes: false) }
                Button("Barcodes") { model.autoRedact(faces: false, text: false, barcodes: true) }
                Divider()
                Button("All of these") { model.autoRedact(faces: true, text: true, barcodes: true) }
            }
            .menuStyle(.button).buttonStyle(.hero(.ghost, size: .sm)).fixedSize()
            .help("Find and cover faces, text or barcodes")
        default: EmptyView()
        }
    }

    @ViewBuilder private var brushOptions: some View {
        if model.tool == .brush { colorWell }
        OptionsButton(title: "Brush", summary: "\(Int(model.options.brushSize)) pt") {
            HeroSlider("Size", value: $model.options.brushSize, in: 1...500, format: { "\(Int($0)) pt" })
            HeroSlider("Hardness", value: $model.options.hardness, in: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })
            HeroSlider("Opacity", value: $model.options.opacity, in: 0.01...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })
        }
        textButton("New layer", help: "Paint on a new layer ⇧⌘N") { model.addPaintLayer() }
    }

    // MARK: Pieces

    private var colorWell: some View {
        ColorPicker(
            "Color",
            selection: Binding(
                get: { Color(cgColor: model.options.color.cgColor) },
                set: { color in
                    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                    model.options.color = RGBA(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
                })
        )
        .labelsHidden()
        .frame(width: 32, height: 32)
        .help("Color")
    }

    private var zoomMenu: some View {
        Menu {
            Button("Zoom to Fit") { model.zoomToFit() }
            Button("Actual Size") { model.actualSize() }
            Button("Zoom to Selection") { model.zoomToSelection() }
            Divider()
            ForEach([0.25, 0.5, 2, 4, 8], id: \.self) { z in
                Button("\(Int(z * 100))%") { model.setZoom(z) }
            }
        } label: {
            Text("\(Int((model.zoomScale * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Hero.foreground)
                .frame(width: 48, height: 32)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Zoom")
        .accessibilityLabel("Zoom \(Int((model.zoomScale * 100).rounded())) percent")
    }

    /// A flyout like Photoshop's: the current variant's icon and name, the rest in a menu.
    private func variantMenu<Items: View>(_ title: String, _ current: String, _ symbol: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(current)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Hero.foreground)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .accessibilityLabel("\(title): \(current)")
    }

    private func button(_ title: String, _ symbol: String, help: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: selected))
            .help(help)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func textButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.hero(.ghost, size: .sm))
            .help(help)
    }
}

/// A compact tool option: its value as a button that opens the sliders in a popover.
private struct OptionsButton<Content: View>: View {
    let title: String
    let summary: String
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(summary).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Hero.muted)
            }
        }
        .buttonStyle(.hero(.ghost, size: .sm, isSelected: shown))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(16)
                .frame(width: 248)
                .background(Hero.overlay)
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(summary)
    }
}

/// Press and hold to see the original; VoiceOver users toggle it instead.
private struct CompareButton: View {
    let model: ImageEditorModel

    var body: some View {
        Button {
        } label: {
            Label("Compare with Original", systemImage: "square.split.2x1")
        }
        .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true, isSelected: model.comparing))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.comparing { model.comparing = true } }
                .onEnded { _ in model.comparing = false }
        )
        .help("Hold to compare with the original (or hold \\)")
        .accessibilityAction(named: "Toggle original") { model.comparing.toggle() }
    }
}
