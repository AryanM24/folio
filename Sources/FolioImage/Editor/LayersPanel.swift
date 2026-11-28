import CoreImage
import FolioKit
import SwiftUI
import UniformTypeIdentifiers

/// The Layers list under the inspector: thumbnails, visibility, lock, blend, opacity,
/// reorder by drag, and adding, grouping, masking, duplicating and deleting. Each change
/// is one undo step. Top of the list is the top of the stack; the photo sits below.
struct LayersPanel: View {
    let model: ImageEditorModel
    @State private var dragging = false

    private var layers: [Layer] { model.recipe.layers }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Hero.separator).frame(height: 1)
            List(selection: Bindable(model.layerState).selectedID) {
                ForEach(layers.reversed()) { layer in
                    LayerRow(model: model, layer: layer)
                        .tag(layer.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowBackground(model.layerState.selectedID == layer.id))
                }
                .onMove { from, to in
                    let (source, destination) = Self.stackMove(from: from, to: to, count: layers.count)
                    model.moveLayers(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 40)
            .accessibilityLabel("Layers")
            BackgroundRow(model: model)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            Rectangle().fill(Hero.separator).frame(height: 1)
            footer
        }
        .heroOverlay(cornerRadius: Hero.Radius.xxxl)
    }

    private func rowBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Hero.Radius.lg)
            .fill(selected ? Hero.accentSoft : .clear)
            .padding(.horizontal, 4)
    }

    /// List offsets (top first) → `moveLayers` offsets (bottom first).
    nonisolated static func stackMove(from: IndexSet, to: Int, count: Int) -> (IndexSet, Int) {
        (IndexSet(from.map { count - 1 - $0 }), count - to)
    }

    // MARK: Header and footer

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Layers").font(.system(size: 13, weight: .semibold)).foregroundStyle(Hero.foreground)
                Spacer()
                if let layer = model.selectedLayer {
                    Menu {
                        BlendModeItems(model: model, layer: layer)
                    } label: {
                        Text(layer.blend.title).font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(.button).buttonStyle(.hero(.ghost, size: .sm)).fixedSize()
                    .help("Blend mode")
                    .accessibilityLabel("Blend mode \(layer.blend.title)")
                }
            }
            if let layer = model.selectedLayer {
                HeroSlider(
                    "Opacity",
                    value: Binding(get: { layer.opacity }, set: { model.setLayerOpacity(layer.id, $0, live: dragging) }),
                    in: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" }
                ) { editing in
                    if editing {
                        dragging = true
                    } else if dragging {
                        dragging = false
                        model.endLive("Layer Opacity")
                    }
                }
                .disabled(layer.isLocked)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Menu {
                AddLayerItems(model: model)
            } label: {
                Label("Add Layer", systemImage: "plus")
            }
            .menuStyle(.button).buttonStyle(.hero(.ghost, size: .sm, iconOnly: true)).menuIndicator(.hidden).fixedSize()
            .help("Add a layer")
            icon("Add Mask from Selection", "square.dashed.inset.filled", help: "Mask the layer with the selection") {
                model.addMaskFromSelection()
            }
            .disabled(model.selectedLayer == nil || model.selectionState.spec == nil)
            icon("Group", "folder", help: "Group ⌘G") { model.groupSelectedLayer() }
                .disabled(model.selectedLayer == nil)
            icon("Duplicate", "plus.square.on.square", help: "Duplicate ⌘J") { model.duplicateSelectedLayer() }
                .disabled(model.selectedLayer == nil)
            Spacer()
            icon("Delete Layer", "trash", help: "Delete the layer ⌫") { model.deleteSelectedLayer() }
                .disabled(model.selectedLayer == nil || model.selectedLayer?.isLocked == true)
        }
        .padding(8)
    }

    private func icon(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
            .help(help)
    }
}

/// Everything "New Layer" can make, for the panel's + menu and the Layer menu.
struct AddLayerItems: View {
    let model: ImageEditorModel

    var body: some View {
        Button("Image from File…") { model.addImageLayerFromFile() }
        Button("Text") { model.addTextLayer() }
        Button("Shape") { model.addShapeLayer() }
        Button("Paint") { model.addPaintLayer() }
        Button("Fill") { model.addFillLayer() }
        Button("Gradient") { model.addGradientLayer() }
        Menu("Adjustment") {
            Button("Adjustments") { model.addAdjustmentLayer(.adjustments(Adjustments())) }
            Button("Tone") { model.addAdjustmentLayer(.tone(ToneSpec())) }
            Button("Blur") { model.addAdjustmentLayer(.blur(radius: 12)) }
            Button("Pixelate") { model.addAdjustmentLayer(.pixelate(size: 16)) }
            Divider()
            ForEach(FilterPreset.allCases) { preset in
                Button(preset.title) { model.addAdjustmentLayer(.filter(preset, strength: 1)) }
            }
        }
    }
}

extension ImageEditorModel {
    /// Ask for an image file and place it as a new layer.
    func addImageLayerFromFile() {
        Task {
            guard let url = await Exporter.pick(types: [.image], multiple: false).first else { return }
            do {
                let data = try await offCooperativePool { try Data(contentsOf: url) }
                try addImageLayer(data, name: url.deletingPathExtension().lastPathComponent)
            } catch {
                show(error, title: "Couldn't add “\(url.lastPathComponent)”")
            }
        }
    }
}

/// One layer: thumbnail, mask thumbnail, name, then visibility and lock.
private struct LayerRow: View {
    let model: ImageEditorModel
    let layer: Layer

    private var selected: Bool { model.layerState.selectedID == layer.id }

    var body: some View {
        HStack(spacing: 8) {
            LayerThumbnail(model: model, layer: layer, mask: false)
            if layer.mask != nil { LayerThumbnail(model: model, layer: layer, mask: true) }
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Hero.accentSoftForeground : Hero.foreground)
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Hero.muted).lineLimit(1)
                }
            }
            .opacity(layer.isVisible ? 1 : 0.5)
            Spacer(minLength: 4)
            toggle(layer.isLocked ? "Unlock" : "Lock", layer.isLocked ? "lock.fill" : "lock.open", shown: layer.isLocked) {
                model.setLayerLocked(layer.id, !layer.isLocked)
            }
            toggle(layer.isVisible ? "Hide" : "Show", layer.isVisible ? "eye" : "eye.slash", shown: true) {
                model.setLayerVisible(layer.id, !layer.isVisible)
            }
        }
        .frame(height: 40)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layer.name)
        .accessibilityValue([layer.isVisible ? "Visible" : "Hidden", layer.isLocked ? "locked" : nil, detail].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: layer.isVisible ? "Hide" : "Show") { model.setLayerVisible(layer.id, !layer.isVisible) }
        .accessibilityAction(named: layer.isLocked ? "Unlock" : "Lock") { model.setLayerLocked(layer.id, !layer.isLocked) }
        .accessibilityAction(named: "Delete") {
            model.layerState.selectedID = layer.id
            model.deleteSelectedLayer()
        }
        .contextMenu {
            Button("Duplicate") { select(); model.duplicateSelectedLayer() }
            Button("Group") { select(); model.groupSelectedLayer() }
            if case .group = layer.content { Button("Ungroup") { select(); model.ungroupSelectedLayer() } }
            Button("Merge Down") { select(); model.mergeDown() }
            Button("Rasterize") { select(); model.rasterizeSelectedLayer() }
            Divider()
            Button("Delete", role: .destructive) { select(); model.deleteSelectedLayer() }
        }
    }

    private func select() { model.layerState.selectedID = layer.id }

    /// Blend and opacity when they aren't the defaults.
    private var detail: String? {
        var parts: [String] = []
        if layer.blend != .normal { parts.append(layer.blend.title) }
        if layer.opacity < 0.995 { parts.append("\(Int((layer.opacity * 100).rounded()))%") }
        if layer.clipsToBelow { parts.append("Clipped") }
        if case .group(let g) = layer.content { parts.append(g.layers.count == 1 ? "1 layer" : "\(g.layers.count) layers") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The lock shows when locked or on the selected row, to keep rows calm; the eye always shows.
    private func toggle(_ title: String, _ symbol: String, shown: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
            .help(title)
            .opacity(shown || selected ? 1 : 0)
    }
}

/// The photo under every layer. Selecting it deselects the layers.
private struct BackgroundRow: View {
    let model: ImageEditorModel

    var body: some View {
        let selected = model.layerState.selectedID == nil
        Button {
            model.layerState.selectedID = nil
        } label: {
            HStack(spacing: 8) {
                Image(decorative: model.source.proxy, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .background(Hero.surfaceSecondary)
                    .clipShape(.rect(cornerRadius: Hero.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Hero.Radius.sm).strokeBorder(Hero.border, lineWidth: 1))
                Text("Photo")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Hero.accentSoftForeground : Hero.foreground)
                Spacer()
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Hero.muted)
                    .frame(width: 32)
                    .help("The photo is edited with Adjust, Tone and Filters")
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(selected ? Hero.accentSoft : .clear, in: .rect(cornerRadius: Hero.Radius.lg))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo, the background")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A 32-point picture of a layer's content or mask, rendered in the background.
private struct LayerThumbnail: View {
    let model: ImageEditorModel
    let layer: Layer
    let mask: Bool
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Hero.surfaceSecondary
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Hero.muted)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(.rect(cornerRadius: Hero.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Hero.Radius.sm).strokeBorder(Hero.border, lineWidth: 1))
        .task(id: Key(layer: layer, mask: mask)) {
            let (source, recipe, assets) = (model.source, model.recipe, model.document.assets)
            let layer = layer, mask = mask
            image = try? await offCooperativePool { Self.render(layer, mask: mask, source: source, recipe: recipe, assets: assets) }
        }
        .accessibilityHidden(true)
    }

    private struct Key: Equatable {
        let layer: Layer
        let mask: Bool
    }

    private var symbol: String {
        if mask { return "square.dashed.inset.filled" }
        switch layer.content {
        case .adjustment: return "slider.horizontal.3"
        case .retouch: return "bandage"
        case .group: return "folder"
        case .text: return "textformat"
        default: return "square.3.layers.3d"
        }
    }

    /// Blocking: run off the cooperative pool.
    nonisolated private static func render(
        _ layer: Layer, mask: Bool, source: SourceImage, recipe: EditRecipe, assets: any AssetStore
    ) -> CGImage? {
        let size = source.pixelSize
        let scale = 64 / max(1, max(size.width, size.height))
        let extent = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let image: CIImage?
        if mask {
            switch layer.mask?.source {
            case .selection(let spec):
                image = try? ImageEditorModel.selectionMask(spec, source: source, recipe: recipe, assets: assets, scale: scale)
            case .pixels(let id):
                image = LayerCompositor.decoded(id, assets: assets).map { m in
                    m.transformed(by: CGAffineTransform(scaleX: extent.width / max(1, m.extent.width), y: extent.height / max(1, m.extent.height)))
                }
            default: image = nil
            }
        } else {
            if layer.coversDocument { return nil }
            var plain = layer
            plain.opacity = 1
            plain.isVisible = true
            plain.blend = .normal
            plain.mask = nil
            image = LayerCompositor.composite(base: CIImage(color: .clear).cropped(to: extent), layers: [plain], assets: assets, scale: scale)
        }
        guard let image else { return nil }
        return RenderPipeline.context.createCGImage(image.cropped(to: extent), from: extent)
    }
}
